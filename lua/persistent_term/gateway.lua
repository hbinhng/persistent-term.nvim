-- lua/persistent_term/gateway.lua
local M = {}

local Gateway = {}
Gateway.__index = Gateway

local function default_log()
  return require("persistent_term.log")
end

local function version_at_least(have, want)
  -- "3.0", "3.0a", "3.2-rc2" -> compare numeric tuple prefix.
  local function nums(s)
    local out = {}
    for c in s:gmatch("(%d+)") do
      table.insert(out, tonumber(c))
    end
    return out
  end
  local h, w = nums(have), nums(want)
  for i = 1, math.max(#h, #w) do
    local a, b = h[i] or 0, w[i] or 0
    if a ~= b then
      return a > b
    end
  end
  return true
end

--- Construct a new gateway. Does not start the subprocess; call gw:start().
--- @param opts table  { transport = <table>, log = <optional> }
function M.new(opts)
  assert(type(opts) == "table", "opts required")
  assert(type(opts.transport) == "table", "opts.transport required")
  local self = setmetatable({}, Gateway)
  self._transport = opts.transport
  self._log = opts.log or default_log()
  self._state = "stopped"
  self._stdout_buf = ""
  self._pending = {} -- FIFO of { cmd, cb }
  self._in_block = false
  self._block_lines = {}
  -- pane_id -> { on_bytes, on_close, window_id }
  self._subs = {}
  self._version = nil -- string, populated by bootstrap or _set_version_for_test
  return self
end

function Gateway:state()
  return self._state
end

local function on_stdout(self, chunk)
  if chunk == nil or chunk == "" then
    return
  end
  self._stdout_buf = self._stdout_buf .. chunk
  while true do
    local nl = self._stdout_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self._stdout_buf:sub(1, nl - 1)
    self._stdout_buf = self._stdout_buf:sub(nl + 1)
    self:_handle_line(line)
  end
end

local function on_stderr(self, chunk)
  if not chunk or chunk == "" then
    return
  end
  -- Trim trailing newline for logging.
  local msg = chunk:gsub("[\r\n]+$", "")
  if msg ~= "" then
    self._log.warn("tmux -CC stderr: " .. msg)
  end
end

local function on_exit(self, _code, _signal)
  self._state = "stopped"
end

function Gateway:start()
  if self._state ~= "stopped" then
    return
  end
  self._state = "starting"
  self._transport.start(function(chunk)
    on_stdout(self, chunk)
  end, function(chunk)
    on_stderr(self, chunk)
  end, function(c, s)
    on_exit(self, c, s)
  end)
end

function Gateway:_handle_line(line)
  -- Track command-response blocks first; they take priority over state
  -- transitions because the initial-attach block also goes through here.
  if self._in_block then
    if line:match("^%%end ") then
      self:_finish_block(true)
    elseif line:match("^%%error ") then
      self:_finish_block(false)
    else
      table.insert(self._block_lines, line)
    end
    return
  end

  if line:match("^%%begin ") then
    self._in_block = true
    self._block_lines = {}
    return
  end

  -- %output %<pane_id> <octal-escaped payload>
  local pid, payload = line:match("^%%output (%%%d+) (.*)$")
  if pid then
    local sub = self._subs[pid]
    if sub then
      local codec = require("persistent_term.codec")
      pcall(sub.on_bytes, codec.decode_output_payload(payload))
    end
    return
  end

  -- %window-close @<wid>
  local wid = line:match("^%%window%-close (@%d+)$")
  if wid then
    for pane_id, sub in pairs(self._subs) do
      if sub.window_id == wid then
        pcall(sub.on_close)
        self._subs[pane_id] = nil
      end
    end
    self:forget_pane_by_window(wid)
    return
  end

  if self._state == "ready_no_session" and line:match("^%%session%-changed ") then
    self._state = "ready"
    self:_run_bootstrap()
    return
  end

  if line == "%exit" or line:match("^%%exit ") then
    self._state = "stopped"
    for _, p in ipairs(self._pending) do
      pcall(p.cb, { ok = false, stderr = "control mode exited" })
    end
    self._pending = {}
    for pane_id, sub in pairs(self._subs) do
      pcall(sub.on_close)
      self._subs[pane_id] = nil
    end
    return
  end

  -- Anything else: log at debug.
  self._log.debug("gateway: unrecognized line: " .. line)
end

function Gateway:_finish_block(ok)
  self._in_block = false
  local body = table.concat(self._block_lines, "\n")
  self._block_lines = {}

  -- The very first %begin/%end after spawn is unsolicited (no caller).
  if self._state == "starting" then
    if ok then
      self._state = "ready_no_session"
    else
      self._state = "stopped"
    end
    return
  end

  local p = table.remove(self._pending, 1)
  if p then
    if ok then
      pcall(p.cb, { ok = true, stdout = body })
    else
      pcall(p.cb, { ok = false, stderr = body })
    end
  end
end

function Gateway:send_cmd(cmd, cb)
  table.insert(self._pending, { cmd = cmd, cb = cb })
  self._transport.write(cmd .. "\n")
end

function Gateway:subscribe(pane_id, window_id, on_bytes, on_close)
  self._subs[pane_id] = {
    window_id = window_id,
    on_bytes = on_bytes,
    on_close = on_close,
  }
end

function Gateway:unsubscribe(pane_id)
  self._subs[pane_id] = nil
end

function Gateway:version()
  return self._version
end

function Gateway:_set_version_for_test(v)
  self._version = v
end

function Gateway:send_keys(pane_id, bytes)
  if bytes == "" then
    return
  end
  local codec = require("persistent_term.codec")
  local cmds = codec.encode_send_keys(bytes, pane_id, self._version or "3.0")
  for _, c in ipairs(cmds) do
    self._transport.write(c .. "\n")
  end
end

function Gateway:detach()
  if self._state == "stopped" or self._state == "detaching" then
    return
  end
  self._state = "detaching"
  self._transport.write("detach\n")
end

function Gateway:_run_bootstrap()
  local self_ref = self
  self:send_cmd("display-message -p '#{version}'", function(r)
    if r.ok then
      self_ref._version = vim.trim(r.stdout)
    end
  end)
  self:send_cmd("set-option -g default-terminal xterm-256color", function() end)
  self:send_cmd("set-environment -g COLORTERM truecolor", function() end)
  -- Gate terminal-features on version. Captured in the previous send_cmd's
  -- callback; we issue this one's request from the callback so it lands
  -- after we know the version.
  self:send_cmd("display-message -p '#{version}'", function(r)
    if r.ok and version_at_least(self_ref._version or "", "3.2") then
      self_ref._transport.write("set-option -g terminal-features xterm-256color:RGB\n")
      table.insert(self_ref._pending, { cmd = "<deferred-terminal-features>", cb = function() end })
    end
  end)
end

function Gateway:ensure_started(timeout_ms)
  if self._state == "ready" then
    return true, nil
  end
  if self._state == "stopped" then
    self:start()
  end
  local ok = vim.wait(timeout_ms or 5000, function()
    return self._state == "ready"
  end, 20)
  if not ok then
    return nil, "tmux -CC startup timeout (state=" .. self._state .. ")"
  end
  return true, nil
end

function Gateway:register_pane(name, pane_id, window_id)
  self._panes_by_name = self._panes_by_name or {}
  self._panes_by_name[name] = { pane_id = pane_id, window_id = window_id }
end

function Gateway:get_pane_by_name(name)
  return (self._panes_by_name or {})[name]
end

function Gateway:forget_pane_by_window(window_id)
  if not self._panes_by_name then
    return
  end
  for n, e in pairs(self._panes_by_name) do
    if e.window_id == window_id then
      self._panes_by_name[n] = nil
    end
  end
end

local _singleton

function M.singleton()
  if not _singleton then
    local transport = M._make_vim_system_transport()
    _singleton = M.new({ transport = transport })
  end
  return _singleton
end

function M._reset_singleton_for_test()
  if _singleton and _singleton._transport and _singleton._transport.kill then
    pcall(_singleton._transport.kill)
  end
  _singleton = nil
end

-- Default production transport. Spawns `tmux -L persistent-term -CC
-- new-session -A -s pterm -x 80 -y 24` and bridges stdin/stdout/stderr.
function M._make_vim_system_transport()
  local handle
  return {
    start = function(on_stdout, on_stderr, on_exit)
      handle = vim.system(
        { "tmux", "-L", "persistent-term", "-CC", "new-session", "-A", "-s", "pterm", "-x", "80", "-y", "24" },
        {
          stdin = true,
          text = true,
          stdout = function(_, chunk)
            if chunk then
              vim.schedule(function()
                on_stdout(chunk)
              end)
            end
          end,
          stderr = function(_, chunk)
            if chunk then
              vim.schedule(function()
                on_stderr(chunk)
              end)
            end
          end,
        },
        function(obj)
          vim.schedule(function()
            on_exit(obj.code, obj.signal)
          end)
        end
      )
      return handle ~= nil, handle == nil and "vim.system failed" or nil
    end,
    write = function(bytes)
      if handle and handle.write then
        handle:write(bytes)
      end
      return true
    end,
    kill = function()
      if handle and handle.kill then
        pcall(handle.kill, handle, 15)
      end
    end,
  }
end

return M
