local config = require("dcat.config")

local M = {}

local OUTPUT_FLAGS = {
  truecolor = "--truecolor-characters",
  palette = "--palette-characters",
  block = "--block-characters",
}

-- Flags that pick an output mode. dcat rejects more than one.
local OUTPUT_ARGS = {
  ["-S"] = true,
  ["--sixel"] = true,
  ["-K"] = true,
  ["--kitty"] = true,
  ["--kitty-direct"] = true,
  ["-T"] = true,
  ["--truecolor-characters"] = true,
  ["-P"] = true,
  ["--palette-characters"] = true,
  ["-B"] = true,
  ["--block-characters"] = true,
}

-- Flags whose value is the next argument, so it isn't taken for the model path
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
---@return string[]
local function output_args(args)
  for _, arg in ipairs(args) do
    if OUTPUT_ARGS[arg] then
      return {}
    end
  end
  -- Neovim's terminal can't show Kitty or Sixel images, but dcat would pick
  -- them from the environment variables it inherits from the outer terminal
  local output = config.options.output or (vim.o.termguicolors and "truecolor" or "palette")
  local flag = OUTPUT_FLAGS[output]
  if not flag then
    error(("dcat: unknown output %q, expected truecolor, palette or block"):format(output))
  end
  return { flag }
end

---@param size number
---@param total integer
local function dimension(size, total)
  local cells = size <= 1 and math.floor(total * size) or size
  return math.max(1, math.min(cells, total))
end

---@param layout dcat.Layout
---@param title string
local function float_config(layout, title)
  if layout == "fullscreen" then
    return {
      relative = "editor",
      row = 0,
      col = 0,
      width = vim.o.columns,
      height = vim.o.lines - vim.o.cmdheight,
      border = "none",
      style = "minimal",
      -- Above other floats, which would otherwise show through
      zindex = 200,
    }
  end
  local float = config.options.float
  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  local width = dimension(float.width, columns - 2)
  local height = dimension(float.height, lines - 2)
  return {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((columns - width - 2) / 2),
    row = math.floor((lines - height - 2) / 2),
    border = float.border,
    title = title,
    title_pos = "center",
    style = "minimal",
  }
end

---@param buf integer
---@param layout dcat.Layout
---@param title string
---@return integer win, integer? previous_buf
local function open_window(buf, layout, title)
  if layout == "float" or layout == "fullscreen" then
    return vim.api.nvim_open_win(buf, true, float_config(layout, title))
  elseif layout == "current" then
    local previous = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)
    return vim.api.nvim_get_current_win(), previous
  elseif layout == "split" or layout == "vsplit" then
    vim.cmd(layout == "split" and "split" or "vsplit")
  elseif layout == "tab" then
    vim.cmd("tab split")
  else
    error(("dcat: unknown layout %q"):format(layout))
  end
  vim.api.nvim_win_set_buf(0, buf)
  return vim.api.nvim_get_current_win()
end

-- The terminal's text, with lines it wrapped at the window edge joined back up
---@param buf integer
---@param width integer
local function terminal_text(buf, width)
  local text = ""
  local wrapped = false
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("%S") then
      text = text .. ((wrapped or text == "") and "" or "\n") .. line
      wrapped = vim.fn.strdisplaywidth(line) >= width
    else
      wrapped = false
    end
  end
  return vim.trim(text:gsub("%[Process exited %d+%]", ""))
end

-- Floats can't cover the command line, so it's hidden while a fullscreen
-- viewer is open. Counted, since a new viewer opens before the old one closes.
local fullscreen_viewers = 0
local saved_cmdheight

local function hide_cmdline()
  if fullscreen_viewers == 0 then
    saved_cmdheight = vim.o.cmdheight
    vim.o.cmdheight = 0
  end
  fullscreen_viewers = fullscreen_viewers + 1
end

local function restore_cmdline()
  fullscreen_viewers = fullscreen_viewers - 1
  if fullscreen_viewers == 0 and saved_cmdheight then
    vim.o.cmdheight = saved_cmdheight
  end
end

-- <C-c> quits dcat, <C-w> is mapped separately, and <C-\\> leaves terminal mode
local NOT_FORWARDED = { ["<C-C>"] = true, ["<C-W>"] = true, ["<C-\\>"] = true, ["<C-Bslash>"] = true }

-- The viewer sends every key to dcat. These go to Neovim instead: <C-w>, : and
-- every single-key Ctrl or Alt normal-mode mapping, none of which dcat uses.
---@param buf integer
local function forward_keys(buf)
  local function map(key, rhs)
    -- Terminal-mode mappings the user made win
    if vim.fn.maparg(key, "t") == "" then
      vim.keymap.set("t", key, rhs, { buffer = buf })
    end
  end

  -- Built in, so they run in normal mode without remapping
  map("<C-W>", "<C-\\><C-n><C-W>")
  map(":", "<C-\\><C-n>:")

  for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
    local key = mapping.lhs or ""
    if key:match("^<[CMA]%-[^>]+>$") and not NOT_FORWARDED[key] then
      map(key, function()
        -- A remapped key fed while still in terminal mode would hit this
        -- mapping again, so it's fed once Neovim is in normal mode
        vim.cmd.stopinsert()
        vim.schedule(function()
          vim.api.nvim_feedkeys(vim.keycode(key), "m", false)
        end)
      end)
    end
  end
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
  local extra = vim.list_extend(vim.deepcopy(config.options.args), opts.args or {})
  vim.list_extend(cmd, output_args(extra))
  vim.list_extend(cmd, extra)
  -- "--" keeps a file named like a flag from being parsed as one
  vim.list_extend(cmd, { "--", path })

  local layout = opts.layout or config.options.layout
  local buf = vim.api.nvim_create_buf(false, true)
  local title = " " .. vim.fn.fnamemodify(path, ":t") .. " "
  local floating = layout == "float" or layout == "fullscreen"
  if layout == "fullscreen" then
    hide_cmdline()
  end
  local ok_win, win, previous = pcall(open_window, buf, layout, title)
  if not ok_win then
    if layout == "fullscreen" then
      restore_cmdline()
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    error(win, 0)
  end

  -- The terminal takes the window's text area, so free up the gutter first.
  -- Set locally, so the window gets its options back when it shows another buffer.
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if layout == "fullscreen" then
      restore_cmdline()
    end
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      if previous and vim.api.nvim_buf_is_valid(previous) then
        vim.api.nvim_win_set_buf(win, previous)
      elseif #vim.api.nvim_tabpage_list_wins(0) > 1 or #vim.api.nvim_list_tabpages() > 1 then
        vim.api.nvim_win_close(win, true)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  local job_opts = {
    on_exit = function(_, code)
      vim.schedule(function()
        local message
        if code ~= 0 and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
          message = terminal_text(buf, vim.api.nvim_win_get_width(win))
          message = message ~= "" and message or ("dcat exited with code " .. code)
        end
        -- Close first, so the message shows with the command line back
        close()
        if message then
          vim.notify(message, vim.log.levels.ERROR)
        end
      end)
    end,
  }

  local ok, job
  if vim.fn.has("nvim-0.11") == 1 then
    job_opts.term = true
    ok, job = pcall(vim.fn.jobstart, cmd, job_opts)
  else
    ---@diagnostic disable-next-line: deprecated
    ok, job = pcall(vim.fn.termopen, cmd, job_opts)
  end
  if not ok or job <= 0 then
    close()
    vim.notify("dcat: failed to start " .. cmd[1] .. (ok and "" or (": " .. job)), vim.log.levels.ERROR)
    return
  end

  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].dcat_path = path
  forward_keys(buf)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    command = "startinsert",
  })
  if floating then
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      buffer = buf,
      callback = function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_config(win, float_config(layout, title))
        end
      end,
    })
    -- A float left behind would keep covering the editor
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(close)
      end,
    })
  end
  vim.cmd.startinsert()
end

-- Load the file into its buffer the way :edit would without the BufReadCmd
---@param buf integer
local function load_as_text(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local escaped = vim.fn.fnameescape(path)
  local bo = vim.bo[buf]
  -- Keeps the buffer as text when it's reloaded with :e
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
    -- Without undo history, u can't bring back the placeholder
    local undolevels = bo.undolevels
    bo.undolevels = -1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    -- ++edit detects the file's format and encoding like :edit does
    vim.cmd("silent keepalt read ++edit " .. escaped)
    vim.cmd("silent 1delete _")
    bo.undolevels = undolevels
    bo.modified = false
    vim.cmd("silent doautocmd BufReadPost " .. escaped)
  end)
end

-- Leave a model file's buffer empty instead of loading its contents
---@param buf integer
local function load_model_buffer(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  -- A new file has nothing to view yet
  if vim.b[buf].dcat_text or vim.fn.filereadable(path) == 0 then
    load_as_text(buf)
    return
  end

  local bo = vim.bo[buf]
  -- nofile keeps :w from writing the placeholder over the model
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
  -- Wait for the UI so the viewer gets the real window size
  if vim.v.vim_did_enter == 1 then
    vim.schedule(open_if_shown)
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = open_if_shown })
  end
end

-- "glb" -> "*.[gG][lL][bB]", since autocmd patterns are case sensitive
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

-- Handle :Dcat [file] [dcat arguments]
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
