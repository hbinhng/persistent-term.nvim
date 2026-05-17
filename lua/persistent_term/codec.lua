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

return M
