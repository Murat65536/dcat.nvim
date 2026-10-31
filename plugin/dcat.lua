if vim.g.loaded_dcat then
  return
end
vim.g.loaded_dcat = true

vim.api.nvim_create_user_command("Dcat", function(opts)
  require("dcat").command(opts.fargs)
end, {
  nargs = "*",
  complete = "file",
  desc = "View a 3D model with dcat",
})

-- Works without setup(); calling setup() re-registers with the new extensions
require("dcat").register_extensions()
