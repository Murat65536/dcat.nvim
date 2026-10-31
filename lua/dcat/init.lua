local config = require("dcat.config")

local M = {}

---@type table<string, dcat.Output>
local OUTPUT_ARGS = {
  ["-S"] = "sixel",
  ["--sixel"] = "sixel",
  ["-K"] = "kitty",
  ["--kitty"] = "kitty",
  ["--kitty-direct"] = "kitty",
  ["-T"] = "truecolor",
  ["--truecolor-characters"] = "truecolor",
  ["-P"] = "palette",
  ["--palette-characters"] = "palette",
  ["-B"] = "block",
  ["--block-characters"] = "block",
}

local CHARACTER_FLAGS = {
  truecolor = "--truecolor-characters",
  palette = "--palette-characters",
  block = "--block-characters",
}

-- Flags that take a value
local VALUE_ARGS = {
  ["-t"] = true,
  ["--texture"] = true,
  ["-n"] = true,
  ["--normal-map"] = true,
  ["-W"] = true,
  ["--width"] = true,
  ["-H"] = true,
  ["--height"] = true,
  ["--camera-distance"] = true,
  ["--model-scale"] = true,
  ["--spin"] = true,
  ["-f"] = true,
  ["--fps"] = true,
  ["--mouse-sensitivity"] = true,
}

local group = vim.api.nvim_create_augroup("dcat", { clear = true })

---@param opts? dcat.Config
function M.setup(opts)
  config.set(opts)
  M.register_extensions()
end

---@param args string[]
---@return dcat.Output?
local function requested_output(args)
  local requested = config.options.output
  for _, arg in ipairs(args) do
    requested = OUTPUT_ARGS[arg] or requested
  end
  return requested
end

---@param args string[] dcat arguments, which may pick a mode themselves
---@return dcat.Output output, string? reason
function M.output(args)
  local requested = requested_output(args)
  if requested and not CHARACTER_FLAGS[requested] and requested ~= "kitty" and requested ~= "sixel" then
    error(("dcat: unknown output %q"):format(requested))
  end

  local pixels = require("dcat.pixels")
  local reason = pixels.unavailable()
  if requested == "kitty" or requested == "sixel" then
    if not reason then
      return requested
    end
  elseif requested then
    return requested
  elseif not reason then
    local protocol = pixels.protocol()
    if protocol then
      return protocol
    end
    reason = "the terminal isn't one known to support Kitty graphics or Sixel"
  end
  return vim.o.termguicolors and "truecolor" or "palette", reason
end

---@class dcat.OpenOpts
---@field args? string[] Arguments added after the configured ones
---@field layout? dcat.Layout Overrides the configured layout

--- Open a model in the dcat viewer
---@param path string
---@param opts? dcat.OpenOpts
function M.open(path, opts)
  opts = opts or {}
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(path) == 0 then
    vim.notify("dcat: can't read " .. path, vim.log.levels.ERROR)
    return
  end
  local cmd = config.cmd()
  if vim.fn.executable(cmd[1]) == 0 then
    vim.notify(("dcat: %s is not executable, see :checkhealth dcat"):format(cmd[1]), vim.log.levels.ERROR)
    return
  end

  local args = vim.list_extend(vim.deepcopy(config.options.args), opts.args or {})
  local output, reason = M.output(args)
  local requested = requested_output(args)
  if reason and (requested == "kitty" or requested == "sixel") then
    vim.notify(("dcat: showing characters, since %s"):format(reason), vim.log.levels.WARN)
  end
  for _, arg in ipairs(args) do
    if not OUTPUT_ARGS[arg] then
      cmd[#cmd + 1] = arg
    end
  end

  local viewer =
    require("dcat.window").open(opts.layout or config.options.layout, " " .. vim.fn.fnamemodify(path, ":t") .. " ")
  vim.b[viewer.buf].dcat_path = path
  if output == "kitty" or output == "sixel" then
    ---@cast output "kitty"|"sixel"
    require("dcat.pixels").start(viewer, output, cmd, path)
  else
    -- dcat would pick graphics from the inherited environment
    vim.list_extend(cmd, { CHARACTER_FLAGS[output], "--", path })
    require("dcat.terminal").start(viewer, cmd)
  end
end

-- Load the file as :edit would
---@param buf integer
local function load_as_text(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local escaped = vim.fn.fnameescape(path)
  local bo = vim.bo[buf]
  vim.b[buf].dcat_text = true
  pcall(vim.keymap.del, "n", "<CR>", { buffer = buf })
  pcall(vim.keymap.del, "n", "e", { buffer = buf })
  bo.buftype = ""
  bo.modifiable = true
  bo.swapfile = vim.go.swapfile

  vim.api.nvim_buf_call(buf, function()
    if vim.fn.filereadable(path) == 0 then
      vim.cmd("silent doautocmd BufNewFile " .. escaped)
      return
    end
    vim.cmd("silent doautocmd BufReadPre " .. escaped)
    -- So u can't bring back the placeholder
    local undolevels = bo.undolevels
    bo.undolevels = -1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.cmd("silent keepalt read ++edit " .. escaped)
    vim.cmd("silent 1delete _")
    bo.undolevels = undolevels
    bo.modified = false
    vim.cmd("silent doautocmd BufReadPost " .. escaped)
  end)
end

---@param buf integer
local function load_model_buffer(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.b[buf].dcat_text or vim.fn.filereadable(path) == 0 then
    load_as_text(buf)
    return
  end

  local bo = vim.bo[buf]
  -- nofile keeps :w from overwriting the model
  bo.buftype = "nofile"
  bo.swapfile = false
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  bo.modifiable = false
  bo.modified = false
  bo.filetype = "dcat"
  vim.keymap.set("n", "<CR>", function()
    M.open(path)
  end, { buffer = buf, desc = "View model in dcat" })
  vim.keymap.set("n", "e", function()
    load_as_text(buf)
  end, { buffer = buf, desc = "Edit model as text" })

  local function open_if_shown()
    if vim.api.nvim_get_current_buf() == buf and not vim.b[buf].dcat_text then
      M.open(path)
    end
  end
  -- Wait for the real window size
  if vim.v.vim_did_enter == 1 then
    vim.schedule(open_if_shown)
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = open_if_shown })
  end
end

-- Autocmd patterns are case sensitive
---@param extension string
local function extension_pattern(extension)
  return "*." .. extension:gsub("%a", function(letter)
    return "[" .. letter:lower() .. letter:upper() .. "]"
  end)
end

function M.register_extensions()
  local autocmd_group = vim.api.nvim_create_augroup("dcat_extensions", { clear = true })
  local extensions = config.options.extensions or {}
  if #extensions == 0 then
    return
  end
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = autocmd_group,
    pattern = vim.tbl_map(extension_pattern, extensions),
    callback = function(ev)
      load_model_buffer(ev.buf)
    end,
  })
end

---@param fargs string[]
function M.command(fargs)
  local path
  local args = {}
  local takes_value = false
  for _, arg in ipairs(fargs) do
    if not path and not takes_value and not vim.startswith(arg, "-") then
      path = arg
    else
      args[#args + 1] = arg
      takes_value = VALUE_ARGS[arg] or false
    end
  end
  path = path or vim.b.dcat_path or vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("dcat: no model given and the current buffer has no file", vim.log.levels.ERROR)
    return
  end
  M.open(path, { args = args })
end

return M
