-- lua/persistent_term/command.lua
local M = {}

local NAME_PATTERN = "^[A-Za-z0-9_.-]+$"

--- Split a string into tokens, treating double-quoted substrings as single tokens.
--- Only splits on whitespace outside of quotes.
local function split_tokens(s)
  local out = {}
  local i = 1
  local len = #s
  while i <= len do
    -- skip whitespace
    while i <= len and s:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then break end
    local tok = ""
    -- collect token (may contain quoted sections)
    while i <= len and not s:sub(i, i):match("%s") do
      local c = s:sub(i, i)
      if c == '"' then
        -- collect until closing quote (or end of string)
        tok = tok .. c
        i = i + 1
        while i <= len and s:sub(i, i) ~= '"' do
          tok = tok .. s:sub(i, i)
          i = i + 1
        end
        if i <= len then
          tok = tok .. s:sub(i, i) -- closing quote
          i = i + 1
        end
      else
        tok = tok .. c
        i = i + 1
      end
    end
    if tok ~= "" then
      table.insert(out, tok)
    end
  end
  return out
end

function M.parse_open_args(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, "usage: :PTerm {name} -- {cmd...}"
  end

  -- Split on the literal " -- " separator to separate name-part from cmd-part.
  -- We look for whitespace-bounded "--" to distinguish it from flags like "--foo".
  local sep_pos = raw:find("%s%-%-%s")
  if not sep_pos then
    -- also check if raw ends with " --" (empty cmd)
    local trail = raw:find("%s%-%-$")
    if trail then
      -- name part exists but argv is empty
      local name_part = raw:sub(1, trail - 1)
      local name_tokens = split_tokens(name_part)
      if #name_tokens ~= 1 then
        return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name_part
      end
      local name = name_tokens[1]
      if #name > 64 or not name:match(NAME_PATTERN) then
        return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name
      end
      return nil, "empty command after --"
    end
    return nil, "missing -- separator before command"
  end

  local name_part = raw:sub(1, sep_pos - 1)
  local cmd_part = raw:sub(sep_pos + 4) -- skip " -- "

  -- Validate name part: must be exactly one valid token
  local name_tokens = split_tokens(name_part)
  if #name_tokens ~= 1 then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name_part
  end
  local name = name_tokens[1]
  if #name > 64 or not name:match(NAME_PATTERN) then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name
  end

  -- Parse argv from cmd_part
  local argv = split_tokens(cmd_part)
  if #argv == 0 then
    return nil, "empty command after --"
  end

  return { name = name, argv = argv }
end

return M
