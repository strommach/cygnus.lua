-- Minimal headless init for running cygnus.lua tests
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
