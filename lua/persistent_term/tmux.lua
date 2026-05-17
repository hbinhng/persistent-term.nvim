-- lua/persistent_term/tmux.lua
local M = {}

M.builders = {}

local SOCKET = { "tmux", "-L", "persistent-term" }
local SAFE_CHARS = "^[%w_%-%./@%%]+$"
local SAFE_TOKEN = "^[a-f0-9]+$"

local function copy(t)
  local r = {}
  for i, v in ipairs(t) do
    r[i] = v
  end
  return r
end

local function ensure_safe(field, value, pattern)
  if type(value) ~= "string" or value == "" or not value:match(pattern) then
    error(string.format("persistent_term.tmux: unsafe value for %s: %q", field, tostring(value)))
  end
end

function M.builders.new_session(opts)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "new-session", "-d",
    "-s", opts.session_name,
    "-x", tostring(opts.cols), "-y", tostring(opts.rows),
    "-c", opts.cwd,
    "-P", "-F", "#{session_id}\t#{pane_id}\t#{window_id}",
    "--",
  })
  vim.list_extend(argv, opts.argv)
  return argv
end

function M.builders.list_panes()
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "list-panes", "-a", "-F", "#{pane_id}\t#{window_id}\t#{@pterm_name}" })
  return argv
end

function M.builders.kill_pane(pane_id)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "kill-pane", "-t", pane_id })
  return argv
end

function M.builders.pipe_pane(opts)
  ensure_safe("bin_path", opts.bin_path, SAFE_CHARS)
  ensure_safe("socket_path", opts.socket_path, SAFE_CHARS)
  ensure_safe("token", opts.token, SAFE_TOKEN)
  local helper = string.format(
    "'%s' --socket '%s' --token '%s'",
    opts.bin_path,
    opts.socket_path,
    opts.token
  )
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "pipe-pane", "-t", opts.pane_id, "-IO", helper })
  return argv
end

function M.builders.capture_pane(pane_id)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "capture-pane", "-p", "-e", "-J",
    "-S", "-", "-E", "-",
    "-t", pane_id,
  })
  return argv
end

function M.builders.resize_pane(pane_id, cols, rows)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "resize-pane", "-t", pane_id,
    "-x", tostring(cols), "-y", tostring(rows),
  })
  return argv
end

function M.builders.resize_window(window_id, cols, rows)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "resize-window", "-t", window_id,
    "-x", tostring(cols), "-y", tostring(rows),
  })
  return argv
end

function M.builders.set_pane_option(pane_id, key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-option", "-p", "-t", pane_id, key, value })
  return argv
end

function M.builders.set_window_option(window_id, key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-option", "-w", "-t", window_id, key, value })
  return argv
end

function M.builders.version_check()
  return { "tmux", "-V" }
end

function M.run(argv, opts)
  opts = opts or {}
  local result = vim.system(argv, {
    text = true,
    timeout = opts.timeout or 5000,
    stdin = opts.stdin,
  }):wait()
  return {
    ok = result.code == 0,
    code = result.code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

function M.is_no_server(res)
  if res.ok or not res.stderr then return false end
  return (res.stderr:find("No such file or directory", 1, true)
    or res.stderr:find("no server running", 1, true)) ~= nil
end

function M.parse_list_panes(stdout)
  local rows = {}
  for line in stdout:gmatch("[^\n]+") do
    local pane_id, window_id, name = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if pane_id then
      table.insert(rows, { pane_id = pane_id, window_id = window_id, name = name or "" })
    end
  end
  return rows
end

function M.parse_new_session_output(stdout)
  local trimmed = stdout:gsub("[\r\n]+$", "")
  local sid, pid, wid = trimmed:match("^(%S+)\t(%S+)\t(%S+)$")
  if not sid then
    return nil
  end
  return { session_id = sid, pane_id = pid, window_id = wid }
end

local function num_tuple(s)
  local out = {}
  for chunk in s:gmatch("(%d+)") do
    table.insert(out, tonumber(chunk))
  end
  return out
end

function M.version_at_least(have, want)
  -- tmux versions look like "3.0", "3.0a", "3.2-rc2". We extract just the
  -- numeric prefix tuple and compare.
  local h, w = num_tuple(have), num_tuple(want)
  for i = 1, math.max(#h, #w) do
    local a, b = h[i] or 0, w[i] or 0
    if a ~= b then
      return a > b
    end
  end
  return true
end

local version_cached = nil
function M.check_version(min)
  if version_cached ~= nil then
    return version_cached
  end
  local res = M.run(M.builders.version_check())
  if not res.ok then
    version_cached = { ok = false, reason = "tmux not found" }
    return version_cached
  end
  local v = res.stdout:match("tmux%s+(%S+)")
  if not v then
    version_cached = { ok = false, reason = "could not parse tmux version: " .. res.stdout }
    return version_cached
  end
  if not M.version_at_least(v, min) then
    version_cached = { ok = false, reason = string.format("tmux %s found; %s required", v, min) }
  else
    version_cached = { ok = true, version = v }
  end
  return version_cached
end

function M._reset_version_cache()
  version_cached = nil
end

return M
