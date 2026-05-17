-- lua/persistent_term/codec.lua
local M = {}

--- Decode a tmux %output payload (octal-escaped ASCII) into a byte string.
--- Mirrors iTerm2's TmuxGateway -decodeEscapedOutput: bytes < 0x20 are
--- line-buffering chrome and skipped; "\NNN" introduces a 3-digit octal byte;
--- bytes >= 0x20 pass through literally (including UTF-8 continuation bytes).
function M.decode_output_payload(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x20 then
      i = i + 1
    elseif c == 0x5c then -- '\'
      local b, consumed = 0, 0
      local j = i + 1
      while consumed < 3 and j <= n do
        local d = s:byte(j)
        -- Skip stray \r mid-octal (tmux line-buffering chrome).
        if d == 0x0d then
          j = j + 1
        elseif d >= 0x30 and d <= 0x37 then
          b = b * 8 + (d - 0x30)
          consumed = consumed + 1
          j = j + 1
        else
          break
        end
      end
      if consumed == 3 then
        table.insert(out, string.char(b))
        i = j
      else
        -- Malformed: replace with '?' and skip the '\'.
        table.insert(out, "?")
        i = i + 1
      end
    else
      table.insert(out, string.char(c))
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Quote a string for use as a single argument in a tmux command line.
--- Wraps in single quotes; embedded single quotes become '\'' (close, escaped,
--- reopen). Suitable for inserting an opaque user-provided value into a
--- tmux command we send over the -CC channel.
function M.shell_escape(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

--- Remove libvterm's auto-response CSI sequences from `data`, returning the
--- bytes that should be forwarded as actual keystrokes.
---
--- A CSI auto-response has the shape:
---   ESC '['  [0-9;?>]*  final-byte ∈ {R, c, n}
---
--- User-typed CSI sequences (arrows, function keys, modified keys) always end
--- in letters or '~', never in R/c/n, so they pass through unchanged. Bare
--- ESC and ESC-O (SS3) sequences are not CSI and also pass through.
function M.is_libvterm_response(data)
  local out = {}
  local i, n = 1, #data
  while i <= n do
    local b = data:byte(i)
    if b == 0x1b and i + 1 <= n and data:byte(i + 1) == 0x5b then -- ESC [
      -- Walk the parameter section: [0-9;?>]*
      local j = i + 2
      while j <= n do
        local p = data:byte(j)
        if
          (p >= 0x30 and p <= 0x39) -- 0-9
          or p == 0x3b -- ;
          or p == 0x3f -- ?
          or p == 0x3e -- >
        then
          j = j + 1
        else
          break
        end
      end
      if j > n then
        -- Incomplete CSI at buffer tail; pass through unchanged.
        table.insert(out, data:sub(i))
        i = n + 1
      else
        local final = data:byte(j)
        if final == 0x52 or final == 0x63 or final == 0x6e then -- R, c, n
          -- Drop the whole sequence.
          i = j + 1
        else
          -- Keep the sequence verbatim (it's a real keystroke).
          table.insert(out, data:sub(i, j))
          i = j + 1
        end
      end
    else
      table.insert(out, string.char(b))
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Encoder bucket tags. Stable values; tested directly.
local BUCKET_LITERAL = 1
local BUCKET_HEX = 2
local BUCKET_LITERAL_BYTE = 3

local function is_printable_allowlist(c)
  -- A-Z, a-z, 0-9
  if (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5a) or (c >= 0x61 and c <= 0x7a) then
    return true
  end
  -- + / ) : , _
  return c == 0x2b or c == 0x2f or c == 0x29 or c == 0x3a or c == 0x2c or c == 0x5f
end

local function bucket_for(c, literal_byte_supported)
  if is_printable_allowlist(c) then
    return BUCKET_LITERAL
  end
  if c <= 0x1f and literal_byte_supported then
    return BUCKET_LITERAL_BYTE
  end
  return BUCKET_HEX
end

local function version_ge_3_0a(version)
  -- iTerm2 encodes 3.0a as decimal 3.01. We compare component tuples instead
  -- (simpler in Lua): "3.0" -> {3, 0}, "3.0a" -> {3, 0, "a"}.
  local major, minor = version:match("^(%d+)%.(%d+)")
  if not major then
    return false
  end
  major, minor = tonumber(major), tonumber(minor)
  if major > 3 then
    return true
  end
  if major < 3 then
    return false
  end
  if minor > 0 then
    return true
  end
  -- major.minor == 3.0; need a suffix letter to be 3.0a+.
  local suffix = version:match("^%d+%.%d+(%a+)")
  return suffix ~= nil
end

--- Encode a byte string into one or more `send-keys` command lines for tmux.
--- @param bytes string raw byte input (already auto-response-filtered)
--- @param pane_id string tmux pane id like "%1"
--- @param version string tmux version (e.g. "3.0", "3.0a", "3.4-rc1")
--- @return string[] list of command lines (no trailing newline), to be sent
---         in order over the control-mode channel.
function M.encode_send_keys(bytes, pane_id, version)
  if bytes == "" then
    return {}
  end
  local lb = version_ge_3_0a(version)

  local cmds = {}
  local i, n = 1, #bytes
  while i <= n do
    local c = bytes:byte(i)
    local b = bucket_for(c, lb)
    local j = i
    while j <= n and bucket_for(bytes:byte(j), lb) == b do
      j = j + 1
    end
    local run = bytes:sub(i, j - 1)
    if b == BUCKET_LITERAL then
      table.insert(cmds, "send-keys -lt " .. pane_id .. " " .. M.shell_escape(run))
    elseif b == BUCKET_HEX then
      local parts = {}
      for k = 1, #run do
        table.insert(parts, string.format("0x%02x", run:byte(k)))
      end
      table.insert(cmds, "send-keys -t " .. pane_id .. " " .. table.concat(parts, " "))
    else -- BUCKET_LITERAL_BYTE
      local parts = {}
      for k = 1, #run do
        table.insert(parts, string.format("%02x", run:byte(k)))
      end
      table.insert(cmds, "send-keys -H -t " .. pane_id .. " " .. table.concat(parts, " "))
    end
    i = j
  end
  return cmds
end

return M
