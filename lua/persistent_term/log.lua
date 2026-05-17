-- lua/persistent_term/log.lua
local M = {}

local debug_enabled = (vim.env.PERSISTENT_TERM_DEBUG == "1")

local function log_path()
  if vim.env.PERSISTENT_TERM_LOG_PATH and vim.env.PERSISTENT_TERM_LOG_PATH ~= "" then
    return vim.env.PERSISTENT_TERM_LOG_PATH
  end
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  return dir .. "/persistent-term.log"
end

local function maybe_rotate(path)
  local size = vim.fn.getfsize(path)
  if size <= 0 or size <= 1024 * 1024 then
    return
  end
  os.rename(path, path .. ".1")
end

local function write(level, msg)
  local path = log_path()
  maybe_rotate(path)
  local line = string.format("%s %-5s %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), level, msg)
  local fp = io.open(path, "a")
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
