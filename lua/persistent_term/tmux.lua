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
  vim.list_extend(argv, { "list-panes", "-a", "-F", "#{pane_id} #{@pterm_name}" })
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

return M
