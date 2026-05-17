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

return M
