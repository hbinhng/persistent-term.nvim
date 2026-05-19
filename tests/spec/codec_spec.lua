-- tests/spec/codec_spec.lua
describe("codec.decode_output_payload", function()
  local codec
  before_each(function()
    package.loaded["persistent_term.codec"] = nil
    codec = require("persistent_term.codec")
  end)

  it("passes printable ASCII through unchanged", function()
    assert.equals("hello", codec.decode_output_payload("hello"))
  end)

  it("decodes \\033 to ESC (0x1b)", function()
    assert.equals("\27[K", codec.decode_output_payload("\\033[K"))
  end)

  it("decodes \\134 to literal backslash", function()
    assert.equals("a\\b", codec.decode_output_payload("a\\134b"))
  end)

  it("decodes \\007 to BEL (0x07)", function()
    assert.equals("\7", codec.decode_output_payload("\\007"))
  end)

  it("skips bytes < 0x20 between escapes (line-buffering chrome)", function()
    -- tmux can sprinkle \r in the encoded stream; the decoder drops them.
    assert.equals("ab", codec.decode_output_payload("a\rb"))
  end)

  it("survives UTF-8 multibyte sequences (continuation bytes >= 0x80)", function()
    -- 'é' is 0xc3 0xa9 — both bytes >= 0x80, no escaping needed on the wire.
    assert.equals("\xc3\xa9", codec.decode_output_payload("\xc3\xa9"))
  end)

  it("skips \\r embedded inside an octal triple", function()
    -- Wire bytes: \, 1, CR, 3, 4  →  octal 134 = 92 = literal backslash.
    -- The CR lands between the first and second octal digits; the mid-octal
    -- skip branch (codec.lua:21-22) must absorb it and still accumulate all
    -- three digits before emitting the decoded byte.
    assert.equals("\\", codec.decode_output_payload("\\1\r34"))
  end)

  it("replaces a malformed \\ followed by non-octal with '?'", function()
    -- Forgiving recovery per iTerm2's TmuxGateway.m:165-168.
    local out = codec.decode_output_payload("\\X")
    -- The byte where \ started becomes '?'; the X passes through.
    assert.equals("?X", out)
  end)

  it("replaces a lone trailing \\ with '?'", function()
    -- Payload ends immediately after the backslash: consumed stays 0,
    -- so the malformed-escape branch fires and emits '?'.
    assert.equals("?", codec.decode_output_payload("\\"))
  end)

  it("decodes a full %output payload with CSI", function()
    -- \\033[6n => ESC [ 6 n  (the DSR-CPR query bytes).
    assert.equals("\27[6n", codec.decode_output_payload("\\033[6n"))
  end)
end)

describe("codec.shell_escape", function()
  local codec
  before_each(function()
    package.loaded["persistent_term.codec"] = nil
    codec = require("persistent_term.codec")
  end)

  it("wraps a simple word in single quotes", function()
    assert.equals("'hello'", codec.shell_escape("hello"))
  end)

  it("wraps an empty string in single quotes", function()
    assert.equals("''", codec.shell_escape(""))
  end)

  it("escapes embedded single quotes via '\\''", function()
    assert.equals([['it'\''s']], codec.shell_escape("it's"))
  end)

  it("preserves spaces inside the quoted value", function()
    assert.equals("'echo hi'", codec.shell_escape("echo hi"))
  end)

  it("preserves backslashes inside the quoted value (single quotes are literal)", function()
    assert.equals([['a\b']], codec.shell_escape([[a\b]]))
  end)
end)

describe("codec.is_libvterm_response", function()
  local codec
  before_each(function()
    package.loaded["persistent_term.codec"] = nil
    codec = require("persistent_term.codec")
  end)

  it("strips a CPR response", function()
    -- \e[24;80R = cursor at row 24 col 80
    local cleaned = codec.is_libvterm_response("\27[24;80R")
    assert.equals("", cleaned)
  end)

  it("strips a DA1 response (CSI ? ... c)", function()
    local cleaned = codec.is_libvterm_response("\27[?1;2c")
    assert.equals("", cleaned)
  end)

  it("strips a DA2 response (CSI > ... c)", function()
    local cleaned = codec.is_libvterm_response("\27[>1;100;0c")
    assert.equals("", cleaned)
  end)

  it("strips a DSR-OK response (CSI 0 n)", function()
    local cleaned = codec.is_libvterm_response("\27[0n")
    assert.equals("", cleaned)
  end)

  it("keeps an arrow-key sequence (CSI A)", function()
    assert.equals("\27[A", codec.is_libvterm_response("\27[A"))
  end)

  it("keeps a function-key sequence (CSI 15 ~)", function()
    assert.equals("\27[15~", codec.is_libvterm_response("\27[15~"))
  end)

  it("keeps a modified-key sequence (CSI 1 ; 5 A = Ctrl-Up)", function()
    assert.equals("\27[1;5A", codec.is_libvterm_response("\27[1;5A"))
  end)

  it("keeps plain text", function()
    assert.equals("hello", codec.is_libvterm_response("hello"))
  end)

  it("keeps a SS3 function key (\\eOP = F1)", function()
    -- \eO sequences are NOT CSI and must pass through.
    assert.equals("\27OP", codec.is_libvterm_response("\27OP"))
  end)

  it("strips a response embedded between user keystrokes", function()
    local data = "ab\27[24;80Rcd"
    assert.equals("abcd", codec.is_libvterm_response(data))
  end)

  it("handles an incomplete CSI at the buffer tail (no final byte)", function()
    -- Conservatively pass through; the caller will buffer and retry.
    local data = "ab\27["
    assert.equals("ab\27[", codec.is_libvterm_response(data))
  end)

  it("keeps a bare ESC followed by non-[", function()
    assert.equals("\27a", codec.is_libvterm_response("\27a"))
  end)
end)

describe("codec.encode_send_keys", function()
  local codec
  before_each(function()
    package.loaded["persistent_term.codec"] = nil
    codec = require("persistent_term.codec")
  end)

  it("encodes a pure printable string as one literal command", function()
    local cmds = codec.encode_send_keys("hello", "%1", "3.4")
    assert.same({ "send-keys -lt %1 'hello'" }, cmds)
  end)

  it("encodes a single Enter (0x0d) as literal-byte on tmux >= 3.0a", function()
    local cmds = codec.encode_send_keys("\r", "%1", "3.0a")
    assert.same({ "send-keys -H -t %1 0d" }, cmds)
  end)

  it("encodes a single Enter (0x0d) as hex on tmux 3.0", function()
    local cmds = codec.encode_send_keys("\r", "%1", "3.0")
    assert.same({ "send-keys -t %1 0x0d" }, cmds)
  end)

  it("encodes left-arrow (ESC [ D) as three batched commands on 3.4", function()
    -- \e is C0 -> literal-byte; [ is hex (not in printable allow-list); D is alnum -> literal.
    local cmds = codec.encode_send_keys("\27[D", "%1", "3.4")
    assert.same({
      "send-keys -H -t %1 1b",
      "send-keys -t %1 0x5b",
      "send-keys -lt %1 'D'",
    }, cmds)
  end)

  it("batches a run of printable bytes into one command", function()
    local cmds = codec.encode_send_keys("abc123", "%2", "3.4")
    assert.same({ "send-keys -lt %2 'abc123'" }, cmds)
  end)

  it("batches a run of C0 bytes into one literal-byte command", function()
    -- \x01\x02\x03 -> Ctrl-A Ctrl-B Ctrl-C
    local cmds = codec.encode_send_keys("\1\2\3", "%1", "3.4")
    assert.same({ "send-keys -H -t %1 01 02 03" }, cmds)
  end)

  it("escapes a literal single quote inside a printable run", function()
    -- Printable run cannot include ', so the ' splits the run into two buckets.
    -- ' is not alnum, not in {+/):,_} -> hex.
    local cmds = codec.encode_send_keys("a'b", "%1", "3.4")
    assert.same({
      "send-keys -lt %1 'a'",
      "send-keys -t %1 0x27",
      "send-keys -lt %1 'b'",
    }, cmds)
  end)

  it("encodes a UTF-8 multibyte sequence as one literal command", function()
    -- é is 0xc3 0xa9. tmux's `send-keys 0xc3` parses 0xc3 as a key code,
    -- not a raw byte, and key codes >= 0x80 outside KEYC_BASE_UCS get
    -- dropped silently. Route UTF-8 high bytes through `send-keys -l`
    -- so tmux decodes them as UTF-8 codepoints and emits them to the pane.
    local cmds = codec.encode_send_keys("\xc3\xa9", "%1", "3.4")
    assert.same({ "send-keys -lt %1 '\xc3\xa9'" }, cmds)
  end)

  it("batches a Vietnamese phrase with ASCII tail into one literal command", function()
    -- "đẹp" is 0xc4 0x91  0xe1 0xba 0xb9  0x70 — three codepoints, six bytes.
    -- The trailing ASCII 'p' must stay in the same literal run, not split off.
    local cmds = codec.encode_send_keys("đẹp", "%1", "3.4")
    assert.same({ "send-keys -lt %1 'đẹp'" }, cmds)
  end)

  it("includes the printable allow-list special chars in the literal bucket", function()
    local cmds = codec.encode_send_keys("a+b/c)d:e,f_g", "%1", "3.4")
    assert.same({ "send-keys -lt %1 'a+b/c)d:e,f_g'" }, cmds)
  end)

  it("returns an empty list for empty input", function()
    local cmds = codec.encode_send_keys("", "%1", "3.4")
    assert.same({}, cmds)
  end)
end)
