local M = {}

function M.check()
  local health = vim.health
  local config = require("dcat.config")
  local options = config.options

  health.start("dcat.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end

  local cmd = config.cmd()
  if vim.fn.executable(cmd[1]) == 0 then
    health.error(("%s is not executable"):format(cmd[1]), {
      "Install dcat: https://github.com/Murat65536/dcat#install",
      "Or point `cmd` in setup() at the binary",
    })
    return
  end

  local version_cmd = vim.list_extend(config.cmd(), { "--version" })
  local result = vim.system(version_cmd, { text = true }):wait(5000)
  if result.code == 0 then
    health.ok(vim.trim(result.stdout) .. " at " .. vim.fn.exepath(cmd[1]))
  else
    health.error(("`%s` failed: %s"):format(table.concat(version_cmd, " "), vim.trim(result.stderr or "")))
  end

  if options.output then
    health.ok("Output mode: " .. options.output)
  elseif vim.o.termguicolors then
    health.ok("Output mode: truecolor ('termguicolors' is set)")
  else
    health.warn("Output mode: palette, because 'termguicolors' is off", {
      "Set 'termguicolors' for full color, or set `output` in setup()",
    })
  end
end

return M
