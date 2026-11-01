-- The Neovim that runs one test case

local root = vim.env.DCAT_TEST_ROOT
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/dcat.lua")
dofile(root .. "/tests/helpers.lua").run(vim.env.DCAT_TEST_SPEC, vim.env.DCAT_TEST_CASE)
