local config = require("dcat.config")

local M = {}

-- Set while a closing viewer puts back the buffer it covered
M.restoring = false

local group = vim.api.nvim_create_augroup("dcat_window", { clear = true })

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

-- Floats can't cover the command line
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

---@class dcat.Viewer
---@field buf integer
---@field win integer
---@field close fun() Closes the viewer. Safe to call more than once.
---@field on_close? fun() Set by the viewer to stop dcat, called once on close

--- Open an empty window for a viewer, focused
---@param layout dcat.Layout
---@param title string
---@return dcat.Viewer
function M.open(layout, title)
  local buf = vim.api.nvim_create_buf(false, true)
  if layout == "fullscreen" then
    hide_cmdline()
  end
  local ok, win, previous = pcall(open_window, buf, layout, title)
  if not ok then
    if layout == "fullscreen" then
      restore_cmdline()
    end
    vim.api.nvim_buf_delete(buf, { force = true })
    error(win, 0)
  end

  -- Local, so the window's options come back with another buffer
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.cursorline = false
  wo.colorcolumn = ""
  wo.list = false
  wo.fillchars = "eob: "

  vim.bo[buf].bufhidden = "wipe"

  local viewer ---@type dcat.Viewer
  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if viewer.on_close then
      viewer.on_close()
    end
    if layout == "fullscreen" then
      restore_cmdline()
    end
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      if previous and vim.api.nvim_buf_is_valid(previous) then
        M.restoring = true
        pcall(vim.api.nvim_win_set_buf, win, previous)
        M.restoring = false
      elseif #vim.api.nvim_tabpage_list_wins(0) > 1 or #vim.api.nvim_list_tabpages() > 1 then
        vim.api.nvim_win_close(win, true)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  viewer = { buf = buf, win = win, close = close }

  -- Neovim only hides a terminal whose job is running, so a viewer no window
  -- shows anymore would keep dcat running
  vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(viewer.close)
    end,
  })
  if layout == "float" or layout == "fullscreen" then
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      buffer = buf,
      callback = function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_config(win, float_config(layout, title))
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(viewer.close)
      end,
    })
  end
  return viewer
end

return M
