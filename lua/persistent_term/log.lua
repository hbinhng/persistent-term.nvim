local M = {}

local debug_enabled = (vim.env.PERSISTENT_TERM_DEBUG == "1")

-- Resolve the log file path once, at module load. This must NOT happen at
-- write time because callers may be in libuv fast-event contexts where
-- vim.fn calls raise E5560.
local function resolve_path()
  if vim.env.PERSISTENT_TERM_LOG_PATH and vim.env.PERSISTENT_TERM_LOG_PATH ~= "" then
    return vim.env.PERSISTENT_TERM_LOG_PATH
  end
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  return dir .. "/persistent-term.log"
end

local log_file_path = resolve_path()

local function file_size(path)
  -- Pure Lua I/O, safe in fast-event contexts.
  local f = io.open(path, "r")
  if not f then
    return 0
  end
  local size = f:seek("end") or 0
  f:close()
  return size
end

local function maybe_rotate(path)
  if file_size(path) > 1024 * 1024 then
    os.rename(path, path .. ".1")
  end
end

local function write(level, msg)
  maybe_rotate(log_file_path)
  local line = string.format("%s %-5s %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), level, msg)
  local fp = io.open(log_file_path, "a")
  if not fp then
    return
  end
  fp:write(line)
  fp:close()
end

function M.error(msg)
  write("ERROR", msg)
  vim.schedule(function()
    vim.notify("[persistent-term] " .. msg, vim.log.levels.ERROR)
  end)
end

function M.warn(msg)
  write("WARN", msg)
  vim.schedule(function()
    vim.notify("[persistent-term] " .. msg, vim.log.levels.WARN)
  end)
end

function M.debug(msg)
  if not debug_enabled then
    return
  end
  write("DEBUG", msg)
end

return M
