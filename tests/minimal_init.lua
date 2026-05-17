local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1).source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/.deps/plenary.nvim")
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
