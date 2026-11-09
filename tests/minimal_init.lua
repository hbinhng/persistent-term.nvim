local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1).source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/.deps/plenary.nvim")
vim.opt.swapfile = false
-- Isolate tests from the user's real server: the integration suite runs
-- `kill-server` between cases.
vim.env.PERSISTENT_TERM_SOCKET = "persistent-term-test"
vim.cmd("runtime plugin/plenary.vim")
