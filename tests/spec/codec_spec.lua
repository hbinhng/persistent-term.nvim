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

  it("replaces a malformed \\ followed by non-octal with '?'", function()
    -- Forgiving recovery per iTerm2's TmuxGateway.m:165-168.
    local out = codec.decode_output_payload("\\X")
    -- The byte where \ started becomes '?'; the X passes through.
    assert.equals("?X", out)
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
