-- plugin/persistent_term.lua
if vim.g.loaded_persistent_term then
  return
end
vim.g.loaded_persistent_term = 1

local function lazy(action)
  return function(opts)
    require("persistent_term")[action](opts.args)
  end
end

vim.api.nvim_create_user_command("PTerm", lazy("open"), {
  nargs = "+",
  desc = "Open a persistent terminal: :PTerm {name} -- {cmd...}",
})

vim.api.nvim_create_user_command("PTermAttach", lazy("attach"), {
  nargs = 1,
  complete = function(arg_lead, cmd_line, cursor_pos)
    return require("persistent_term").complete_attach(arg_lead, cmd_line, cursor_pos)
  end,
  desc = "Attach to an existing tmux pane by name or pane id",
})

vim.api.nvim_create_user_command("PTermKill", function(_)
  require("persistent_term").kill()
end, { desc = "Kill the current persistent terminal" })

vim.api.nvim_create_user_command("PTermList", function(_)
  require("persistent_term").cmd_list()
end, { desc = "List persistent terminals" })

vim.api.nvim_create_augroup("PersistentTermShutdown", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = "PersistentTermShutdown",
  callback = function()
    local ok, gw_mod = pcall(require, "persistent_term.gateway")
    if not ok then
      return
    end
    local gw = gw_mod.singleton()
    if gw and gw.state and gw:state() ~= "stopped" then
      pcall(function()
        gw:detach()
      end)
    end
  end,
})
