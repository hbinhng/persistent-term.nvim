-- lua/persistent_term/gateway.lua
local M = {}

local Gateway = {}
Gateway.__index = Gateway

local function default_log()
  return require("persistent_term.log")
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
    return
  end

  if self._state == "ready_no_session" and line:match("^%%session%-changed ") then
    self._state = "ready"
    return
  end

  if line == "%exit" or line:match("^%%exit ") then
    self._state = "stopped"
    -- Fail any pending callbacks.
    for _, p in ipairs(self._pending) do
      pcall(p.cb, { ok = false, stderr = "control mode exited" })
    end
    self._pending = {}
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

return M
