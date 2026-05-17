-- lua/persistent_term/init.lua
local M = {}

function M.open(raw)
  local handle, err = require("persistent_term.command").cmd_open(raw)
  if err then
    require("persistent_term.log").error(err)
    return nil
  end
  if handle and vim.api.nvim_buf_is_valid(handle.bufnr) then
    vim.cmd.buffer(handle.bufnr)
  end
  return handle
end

function M.attach(target)
  local handle, err = require("persistent_term.command").cmd_attach(target)
  if err then
    require("persistent_term.log").error(err)
    return nil
  end
  if handle and vim.api.nvim_buf_is_valid(handle.bufnr) then
    vim.cmd.buffer(handle.bufnr)
  end
  return handle
end

function M.kill()
  local ok, err = require("persistent_term.command").cmd_kill()
  if not ok then
    require("persistent_term.log").error(err)
  end
end

function M.install()
  local ok, err = require("persistent_term.install").run_install()
  if not ok then
    require("persistent_term.log").error(err)
  end
end

function M.complete_attach(arg_lead, cmd_line, cursor_pos)
  return require("persistent_term.command").complete_attach(arg_lead, cmd_line, cursor_pos)
end

function M.list()
  return require("persistent_term.command").list()
end

function M.cmd_list()
  require("persistent_term.command").cmd_list()
end

return M
