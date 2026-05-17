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

-- Placeholder; full parser comes in Task 5. For now, recognize only the
-- transitions the state-machine tests exercise.
function Gateway:_handle_line(line)
  if self._state == "starting" then
    if line:match("^%%end ") then
      self._state = "ready_no_session"
    elseif line:match("^%%error ") then
      self._state = "stopped"
    end
  elseif self._state == "ready_no_session" then
    if line:match("^%%session%-changed ") then
      self._state = "ready"
    end
  end
  if line == "%exit" or line:match("^%%exit ") then
    self._state = "stopped"
  end
end

return M
