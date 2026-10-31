-- Pixel viewer. :terminal drops images, so dcat runs in a pty and its frames
-- are drawn over the window with nvim_ui_send().

local config = require("dcat.config")

local M = {}

local ffi = require("ffi")
pcall(
  ffi.cdef,
  [[
  struct dcat_winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
  int ioctl(int fd, unsigned long request, ...);
  int shm_unlink(const char *name);
]]
)

local TIOCGWINSZ = jit.os == "OSX" and 0x40087468 or 0x5413
local FRAME_END = "\27[?2026l"
-- Replaces dcat's image id 1, which other plugins may use
local KITTY_IMAGE_ID = 2147483000
local DA1_QUERY = "\27[c"
local KEYS = { "w", "a", "s", "d", "e", "r", "m", "p", "1", "2" }

-- Quit with q, so dcat removes its shared memory
---@param job integer
local function stop(job)
  if not pcall(vim.api.nvim_chan_send, job, "q") then
    return
  end
  vim.defer_fn(function()
    if vim.fn.jobwait({ job }, 0)[1] == -1 then
      vim.fn.jobstop(job)
    end
  end, 3000)
end

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
  if not M.supported() then
    return "this dcat has no --cell-size, which pixels in Neovim need"
  end
end

local supported = {}

---@return boolean
function M.supported()
  local cmd = config.cmd()
  local key = table.concat(cmd, "\0")
  if supported[key] == nil then
    local ok, result = pcall(function()
      return vim.system(vim.list_extend(cmd, { "--help" }), { text = true }):wait(5000)
    end)
    supported[key] = ok and result.code == 0 and result.stdout:find("--cell-size", 1, true) ~= nil
  end
  return supported[key]
end

-- Same detection as dcat
---@return "kitty"|"sixel"|nil
function M.protocol()
  local term = vim.env.TERM or ""
  local program = vim.env.TERM_PROGRAM or ""
  if
    vim.env.KITTY_WINDOW_ID
    or term == "xterm-kitty"
    or term == "xterm-ghostty"
    or program == "ghostty"
    or program == "WezTerm"
  then
    return "kitty"
  end
  if vim.env.KONSOLE_VERSION or program == "iTerm.app" then
    return "sixel"
  end
  for _, name in ipairs({ "foot", "mlterm", "contour", "yaft" }) do
    if vim.startswith(term, name) then
      return "sixel"
    end
  end
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
---@param mode "kitty"|"sixel"
local function text_area(win, mode)
  local info = vim.fn.getwininfo(win)[1]
  local top, left = border_offsets(win)
  local row = info.winrow + top + (info.winbar or 0)
  local rows = info.height
  -- Sixel on the bottom row scrolls the screen
  if mode == "sixel" and row + rows - 1 >= vim.o.lines then
    rows = rows - 1
  end
  return row, info.wincol + left + info.textoff, info.width - info.textoff, rows
end

--- Run dcat in the viewer's window, drawing over it with pixels
---@param viewer dcat.Viewer
---@param mode "kitty"|"sixel"
---@param cmd string[] dcat and its arguments, without an output mode or size
---@param path string The model
function M.start(viewer, mode, cmd, path)
  local buf, win = viewer.buf, viewer.win
  local cell_width, cell_height = cell_pixels()
  if not cell_width or not cell_height then
    viewer.close()
    vim.notify("dcat: the terminal doesn't report its size in pixels", vim.log.levels.ERROR)
    return
  end
  vim.bo[buf].modifiable = false

  local job
  local stopping = false
  local chunks = {}

  -- Kitty can re-place its last image, Sixel has to be resent
  local image_size, placed_at, last_sixel

  local function at_window()
    local row, col = text_area(win, mode)
    return ("\27[?2026h\0277\27[%d;%dH"):format(row, col), row .. "," .. col
  end
  local DRAW_END = "\0278\27[?2026l"

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
    local _, _, columns, rows = text_area(win, mode)
    return size[1] <= columns * cell_width and size[2] <= rows * cell_height
  end

  local function refresh()
    if not visible() or not image_size or not fits(image_size) then
      hide()
      return
    end
    local prefix, at = at_window()
    if at == placed_at then
      return
    end
    if mode == "kitty" then
      vim.api.nvim_ui_send(prefix .. ("\27_Ga=p,i=%d,p=1,q=2,C=1\27\\"):format(KITTY_IMAGE_ID) .. DRAW_END)
    else
      vim.api.nvim_ui_send(prefix .. last_sixel .. DRAW_END)
    end
    placed_at = at
  end

  -- Plain finds, since Lua patterns are far too slow on frames this big
  ---@param output string
  ---@param from integer
  ---@return integer? start, integer? finish, integer? header_end
  local function find_image(output, from)
    if mode == "sixel" then
      -- Sixel data has no ESC
      local start = output:find("\27P", from, true)
      local finish = start and select(2, output:find("\27\\", start, true))
      return start, finish, nil
    end
    local start = output:find("\27_G", from, true)
    local header_end = start and output:find(";", start, true)
    if not start or not header_end then
      return
    end
    local finish
    if output:sub(start, header_end):find("m=1", 1, true) then
      -- Base64 has no ";", so "m=0;" only appears in the last chunk header
      local last = output:find("m=0;", header_end, true)
      finish = last and select(2, output:find("\27\\", last, true))
    else
      -- Shared memory frames are one sequence
      finish = select(2, output:find("\27\\", header_end, true))
    end
    return start, finish, header_end
  end

  -- Unshown shared memory frames must be removed, or dcat stops using it
  ---@param output string
  ---@param from integer
  ---@param to integer
  local function discard(output, from, to)
    local start, finish, header_end = find_image(output, from)
    if not start or not finish or finish > to or not header_end then
      return
    end
    if output:sub(start, header_end):find(",t=s,", 1, true) then
      local ok, name = pcall(vim.base64.decode, output:sub(header_end + 1, finish - 2))
      if ok then
        ffi.C.shm_unlink(name)
      end
    end
  end

  ---@param output string
  ---@param start integer
  ---@param header_end? integer
  ---@return integer[]?
  local function frame_size(output, start, header_end)
    local width, height
    if header_end then
      width, height = output:sub(start, header_end):match("s=(%d+),v=(%d+)")
    else
      width, height = output:match('^\27Pq"1;1;(%d+);(%d+)', start)
    end
    return width and { tonumber(width), tonumber(height) }
  end

  ---@param output string
  ---@param from integer
  ---@param to integer
  local function show(output, from, to)
    local start, finish, header_end = find_image(output, from)
    if not start or not finish or finish > to then
      return
    end
    local size = frame_size(output, start, header_end)
    if not size or not visible() or not fits(size) then
      discard(output, from, to)
      hide()
      return
    end
    local image
    if header_end then
      local header = output:sub(start, header_end):gsub("i=1,p=1", ("i=%d,p=1"):format(KITTY_IMAGE_ID), 1)
      image = header .. output:sub(header_end + 1, finish)
    else
      image = output:sub(start, finish)
      last_sixel = image
    end
    local prefix, at = at_window()
    vim.api.nvim_ui_send(prefix .. image .. DRAW_END)
    image_size, placed_at = size, at
  end

  local query_ids

  -- Relay dcat's shared memory query, which Neovim's pty can't answer
  ---@param output string
  ---@return string? rest Output after the queries, once they're all there
  local function forward_queries(output)
    local da1 = output:find(DA1_QUERY, 1, true)
    if not da1 then
      return
    end
    local queries = {}
    query_ids = {}
    for query in output:sub(1, da1 - 1):gmatch("\27_G[^;]*a=q[^;]*;[^\27]*\27\\") do
      queries[#queries + 1] = query
      query_ids[#query_ids + 1] = query:match("i=(%d+)")
    end
    vim.api.nvim_ui_send(table.concat(queries) .. DA1_QUERY)
    return output:sub(da1 + #DA1_QUERY)
  end

  ---@param sequence string
  local function relay_reply(sequence)
    if not query_ids or not job then
      return
    end
    for _, query_id in ipairs(query_ids) do
      if vim.startswith(sequence, "\27_Gi=" .. query_id .. ";") then
        vim.api.nvim_chan_send(job, vim.endswith(sequence, "\27\\") and sequence or (sequence .. "\27\\"))
        return
      end
    end
    if sequence:match("^\27%[%?[%d;]*c$") then
      vim.api.nvim_chan_send(job, sequence)
      query_ids = nil
    end
  end

  local probing = false

  local function on_output(id, data)
    -- Ignore what a stopped dcat still sends
    if id ~= job then
      return
    end
    local text = table.concat(data, "\n")
    if text == "" then
      return
    end
    chunks[#chunks + 1] = text
    if probing then
      local rest = forward_queries(table.concat(chunks))
      if not rest then
        return
      end
      probing = false
      chunks = { rest }
      text = rest
    end
    local previous_tail = #chunks > 1 and chunks[#chunks - 1]:sub(-#FRAME_END) or ""
    if
      not (previous_tail .. text:sub(1, #FRAME_END)):find(FRAME_END, 1, true) and not text:find(FRAME_END, 1, true)
    then
      return
    end

    local output = table.concat(chunks)
    local frames = {}
    local from = 1
    while true do
      local _, finish = output:find(FRAME_END, from, true)
      if not finish then
        break
      end
      frames[#frames + 1] = { from, finish }
      from = finish + 1
    end
    if #frames == 0 then
      return
    end
    local rest = output:sub(from)
    chunks = rest ~= "" and { rest } or {}

    -- Show only the newest frame, so a slow terminal doesn't fall behind
    for i = 1, #frames - 1 do
      discard(output, frames[i][1], frames[i][2])
    end
    local newest = frames[#frames]
    show(output, newest[1], newest[2])
  end

  local start

  local group = vim.api.nvim_create_augroup("dcat_pixels_" .. buf, { clear = true })

  function viewer.on_close()
    stopping = true
    vim.api.nvim_del_augroup_by_id(group)
    if job and job > 0 then
      stop(job)
    end
    hide()
    if mode == "kitty" and image_size then
      vim.api.nvim_ui_send(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(KITTY_IMAGE_ID))
    end
  end

  -- dcat reserves a row below Sixel images
  local function pty_size()
    local _, _, columns, rows = text_area(win, mode)
    return columns, rows + (mode == "sixel" and 1 or 0)
  end
  local pty

  start = function()
    local columns, rows = pty_size()
    pty = columns .. "x" .. rows
    probing = mode == "kitty"
    query_ids = nil
    local full_cmd = vim.list_extend(vim.deepcopy(cmd), {
      mode == "kitty" and "--kitty" or "--sixel",
      "--cell-size",
      cell_width .. "x" .. cell_height,
      "--",
      path,
    })
    job = vim.fn.jobstart(full_cmd, {
      pty = true,
      width = columns,
      height = rows,
      on_stdout = on_output,
      on_exit = function(id, code)
        vim.schedule(function()
          if id ~= job or stopping then
            return
          end
          -- dcat prints errors after its last frame
          local message = table.concat(chunks):gsub("\27[_P].-\27\\", ""):gsub("\27%[[%d;?]*[%a@]", ""):gsub("\27.", "")
          message = vim.trim(message)
          viewer.close()
          if code ~= 0 then
            vim.notify(message ~= "" and message or ("dcat exited with code " .. code), vim.log.levels.ERROR)
          end
        end)
      end,
    })
    if job <= 0 then
      viewer.close()
      vim.notify("dcat: failed to start " .. cmd[1], vim.log.levels.ERROR)
    end
  end

  -- nowait, so longer mappings don't delay these
  for _, key in ipairs(KEYS) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_chan_send(job, key)
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "q", viewer.close, { buffer = buf, nowait = true })

  -- Resizes go to dcat's pty. A new cell size, from a font change, needs a new dcat.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
    group = group,
    callback = function()
      if stopping then
        return
      end
      local new_width, new_height = cell_pixels()
      if new_width and (new_width ~= cell_width or new_height ~= cell_height) then
        cell_width, cell_height = new_width, new_height
        local old = job
        job = nil
        stop(old)
        chunks = {}
        hide()
        image_size = nil
        start()
        return
      end
      if visible() then
        local columns, rows = pty_size()
        if columns .. "x" .. rows ~= pty then
          pty = columns .. "x" .. rows
          vim.fn.jobresize(job, columns, rows)
        end
      end
      refresh()
    end,
  })
  -- Let dcat remove its shared memory before Neovim exits
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      stopping = true
      if job and job > 0 and pcall(vim.api.nvim_chan_send, job, "q") then
        vim.fn.jobwait({ job }, 2000)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermResponse", {
    group = group,
    callback = function(ev)
      relay_reply(ev.data.sequence)
    end,
  })
  start()
end

return M
