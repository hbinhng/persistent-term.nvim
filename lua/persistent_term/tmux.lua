-- lua/persistent_term/tmux.lua
local M = {}

local function num_tuple(s)
  local out = {}
  for c in s:gmatch("(%d+)") do
    table.insert(out, tonumber(c))
  end
  return out
end

function M.version_at_least(have, want)
  local h, w = num_tuple(have), num_tuple(want)
  for i = 1, math.max(#h, #w) do
    local a, b = h[i] or 0, w[i] or 0
    if a ~= b then
      return a > b
    end
  end
  return true
end

--- Parse a tmux `list-windows -F '#{window_id}\t#{pane_id}\t#{@pterm_name}\t#{pane_dead}'`
--- response body into a list of rows.
function M.parse_list_panes(stdout)
  local rows = {}
  for line in stdout:gmatch("[^\n]+") do
    local wid, pid, name, dead = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t?(.*)$")
    if wid then
      table.insert(rows, {
        window_id = wid,
        pane_id = pid,
        name = name or "",
        dead = dead == "1",
      })
    end
  end
  return rows
end

--- Parse a tmux `new-window -P -F '#{pane_id}\t#{window_id}'` response.
function M.parse_id_tuple(stdout)
  local trimmed = stdout:gsub("[\r\n]+$", "")
  local a, b = trimmed:match("^(%S+)\t(%S+)$")
  if not a then
    return nil
  end
  return { pane_id = a, window_id = b }
end

return M
