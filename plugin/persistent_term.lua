-- plugin/persistent_term.lua
if vim.g.loaded_persistent_term == 1 then
  return
end
vim.g.loaded_persistent_term = 1

local function lazy(fn_name)
  return function(opts)
    require("persistent_term")[fn_name](opts.args)
  end
end

vim.api.nvim_create_user_command("PTerm", lazy("open"), {
  nargs = "+",
  desc = "Open a persistent terminal: :PTerm {name} [-- {cmd...}] (no -- runs $SHELL)",
})

vim.api.nvim_create_user_command("PTermAttach", lazy("attach"), {
  nargs = 1,
  desc = "Attach a buffer to an existing persistent-term pane",
  complete = function(arg_lead, cmd_line, cursor_pos)
    return require("persistent_term").complete_attach(arg_lead, cmd_line, cursor_pos)
  end,
})

vim.api.nvim_create_user_command("PTermKill", function(_)
  require("persistent_term").kill()
end, {
  desc = "Kill the current persistent-term buffer's pane",
})

vim.api.nvim_create_user_command("PTermInstall", function(_)
  require("persistent_term").install()
end, {
  desc = "Download persistent-term-pipe helper binary",
})

vim.api.nvim_create_user_command("PTermList", function(_)
  require("persistent_term").cmd_list()
end, {
  desc = "List persistent-term panes on the tmux server",
})
