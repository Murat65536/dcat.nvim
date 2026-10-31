if vim.g.loaded_dcat then
  return
end
vim.g.loaded_dcat = true

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify_once("dcat.nvim needs Neovim 0.12 or newer", vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command("Dcat", function(opts)
  require("dcat").command(opts.fargs)
end, {
  nargs = "*",
  complete = "file",
  desc = "View a 3D model with dcat",
})

require("dcat").register_extensions()
