-- Pixel viewer. dcat runs in a :terminal, which drops images, so they're taken
-- from TermRequest and drawn over the window with nvim_ui_send().

local config = require("dcat.config")

local M = {}

local ffi = require("ffi")
pcall(
  ffi.cdef,
  [[
  struct dcat_winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
  int ioctl(int fd, unsigned long request, ...);
]]
)

local TIOCGWINSZ = jit.os == "OSX" and 0x40087468 or 0x5413
-- Not dcat's default 1, which other plugins may use
local KITTY_IMAGE_ID = 2147483000

-- Neovim's stdio is the host terminal
---@return integer?, integer?
local function cell_pixels()
  ---@type any
  local size = ffi.new("struct dcat_winsize")
  for _, fd in ipairs({ 1, 0, 2 }) do
    if ffi.C.ioctl(fd, TIOCGWINSZ, size) == 0 and size.ws_xpixel > 0 and size.ws_col > 0 and size.ws_row > 0 then
      return math.floor(size.ws_xpixel / size.ws_col), math.floor(size.ws_ypixel / size.ws_row)
    end
  end
end

local help = {}

-- Whether this dcat has a flag, which older versions may not
---@param flag string
---@return boolean
local function has_flag(flag)
  local cmd = config.cmd()
  local key = table.concat(cmd, "\0")
  if help[key] == nil then
    local ok, result = pcall(function()
      return vim.system(vim.list_extend(cmd, { "--help" }), { text = true }):wait(5000)
    end)
    help[key] = ok and result.code == 0 and result.stdout or ""
  end
  return help[key]:find(flag, 1, true) ~= nil
end

---@return string?
function M.unavailable()
  if
    not vim.tbl_contains(
      vim.tbl_map(function(ui)
        return ui.stdout_tty
      end, vim.api.nvim_list_uis()),
      true
    )
  then
    return "Neovim's UI isn't running in a terminal"
  end
  if vim.env.TMUX or vim.env.STY then
    return "tmux and screen don't pass graphics through"
  end
  if vim.env.NVIM then
    return "Neovim is running inside another Neovim's terminal"
  end
  if not cell_pixels() then
    return "the terminal doesn't report its size in pixels"
  end
  if not has_flag("--detect-output") then
    return "this dcat is too old for pixels in Neovim"
  end
end

local detected = {}

---@return "kitty"|"sixel"|nil
function M.protocol()
  local cmd = config.cmd()
  local key = table.concat(cmd, "\0")
  if detected[key] == nil then
    -- Neovim sets $NVIM for its children, which isn't about the terminal
    local env = vim.fn.environ()
    env.NVIM = nil
    local ok, result = pcall(function()
      return vim
        .system(vim.list_extend(cmd, { "--detect-output" }), { env = env, clear_env = true, text = true })
        :wait(5000)
    end)
    detected[key] = ok and result.code == 0 and vim.trim(result.stdout) or ""
  end
  local output = detected[key]
  return (output == "kitty" or output == "sixel") and output or nil
end

-- getwininfo() positions include a float's border
---@param win integer
---@return integer top, integer left
local function border_offsets(win)
  local border = vim.api.nvim_win_get_config(win).border
  if type(border) ~= "table" or #border == 0 then
    return 0, 0
  end
  local function present(index)
    local side = border[(index - 1) % #border + 1]
    side = type(side) == "table" and side[1] or side
    return side ~= "" and 1 or 0
  end
  return present(2), present(8)
end

---@param win integer
local function text_area(win)
  local info = vim.fn.getwininfo(win)[1]
  local top, left = border_offsets(win)
  return info.winrow + top + (info.winbar or 0),
    info.wincol + left + info.textoff,
    info.width - info.textoff,
    info.height
end

--- Run dcat in the viewer's window, drawing over it with pixels
---@param viewer dcat.Viewer
---@param mode "kitty"|"sixel"
---@param cmd string[] dcat and its arguments, without an output mode or size
---@param path string The model
---@param reopen fun() Opens the viewer again, for when the cell size changes
function M.start(viewer, mode, cmd, path, reopen)
  local buf, win = viewer.buf, viewer.win
  local cell_width, cell_height = cell_pixels()
  if not cell_width or not cell_height then
    viewer.close()
    vim.notify("dcat: the terminal doesn't report its size in pixels", vim.log.levels.ERROR)
    return
  end

  cmd = vim.list_extend(vim.deepcopy(cmd), {
    mode == "kitty" and "--kitty" or "--sixel",
    "--cell-size",
    cell_width .. "x" .. cell_height,
  })
  if mode == "kitty" then
    vim.list_extend(cmd, { "--kitty-image-id", tostring(KITTY_IMAGE_ID) })
    -- Neovim's terminal answers dcat's support query itself, so shared memory
    -- has to be asked for. It only works with the terminal on this machine.
    if not (vim.env.SSH_CONNECTION or vim.env.SSH_TTY) then
      cmd[#cmd + 1] = "--kitty-shared-memory"
    end
  end
  vim.list_extend(cmd, { "--", path })

  -- Kitty can re-place its last image, Sixel has to be resent
  local image_size, placed_at, last_sixel
  -- The Kitty frame arriving in chunks, if it's being shown
  local chunks

  local DRAW_END = "\0278\27[?2026l"
  local function at_window()
    local row, col = text_area(win)
    return ("\27[?2026h\0277\27[%d;%dH"):format(row, col), row .. "," .. col
  end

  local function hide()
    if not placed_at then
      return
    end
    placed_at = nil
    if mode == "kitty" then
      vim.api.nvim_ui_send(("\27_Ga=d,d=i,i=%d,q=2\27\\"):format(KITTY_IMAGE_ID))
    else
      vim.cmd("redraw!")
    end
  end

  local function visible()
    return vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  end

  -- Frames from before a resize can be too big
  ---@param size integer[]
  local function fits(size)
    local _, _, columns, rows = text_area(win)
    return size[1] <= columns * cell_width and size[2] <= rows * cell_height
  end

  ---@param data string
  ---@param size integer[]
  local function draw(data, size)
    local prefix, at = at_window()
    vim.api.nvim_ui_send(prefix .. data .. DRAW_END)
    image_size, placed_at = size, at
  end

  local function refresh()
    if not visible() or not image_size or not fits(image_size) then
      hide()
      return
    end
    local _, at = at_window()
    if at ~= placed_at then
      draw(mode == "kitty" and ("\27_Ga=p,i=%d,p=1,q=2,C=1\27\\"):format(KITTY_IMAGE_ID) or last_sixel, image_size)
    end
  end

  ---@param sequence string Without its terminator
  local function on_kitty(sequence)
    local header_end = sequence:find(";", 1, true) or #sequence + 1
    local keys = sequence:sub(4, header_end - 1)
    -- dcat's support query, which Neovim's terminal has already answered
    if keys:find("a=q", 1, true) then
      return
    end
    local width, height = keys:match("s=(%d+),v=(%d+)")
    if width then
      local size = { tonumber(width), tonumber(height) }
      if not visible() or not fits(size) then
        chunks = nil
        hide()
        return
      end
      chunks = { size = size, sequence .. "\27\\" }
    elseif chunks then
      chunks[#chunks + 1] = sequence .. "\27\\"
    else
      return
    end
    if not keys:find("m=1", 1, true) then
      draw(table.concat(chunks), chunks.size)
      chunks = nil
    end
  end

  ---@param sequence string Without its terminator
  local function on_sixel(sequence)
    local width, height = sequence:match('^\27Pq"1;1;(%d+);(%d+)')
    if not width then
      return
    end
    local size = { tonumber(width), tonumber(height) }
    if not visible() or not fits(size) then
      hide()
      return
    end
    last_sixel = sequence .. "\27\\"
    draw(last_sixel, size)
  end

  local group = vim.api.nvim_create_augroup("dcat_pixels_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("TermRequest", {
    group = group,
    buffer = buf,
    callback = function(ev)
      local sequence = ev.data.sequence
      if mode == "kitty" and vim.startswith(sequence, "\27_G") then
        on_kitty(sequence)
      elseif mode == "sixel" and vim.startswith(sequence, "\27P") then
        on_sixel(sequence)
      end
    end,
  })
  -- The terminal follows the window's size and dcat redraws for it. A new
  -- cell size, from a font change, needs a new dcat.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
    group = group,
    callback = function()
      local new_width, new_height = cell_pixels()
      if new_width and (new_width ~= cell_width or new_height ~= cell_height) and visible() then
        vim.api.nvim_set_current_win(win)
        viewer.close()
        reopen()
        return
      end
      refresh()
    end,
  })

  function viewer.on_close()
    vim.api.nvim_del_augroup_by_id(group)
    hide()
    if mode == "kitty" and image_size then
      vim.api.nvim_ui_send(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(KITTY_IMAGE_ID))
    end
  end

  require("dcat.terminal").start(viewer, cmd)
end

return M
