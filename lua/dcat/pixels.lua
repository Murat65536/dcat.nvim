-- The pixel viewer: dcat's Kitty or Sixel output in a Neovim window.
--
-- Neovim's :terminal drops image escape sequences, so dcat runs in a plain pty
-- job instead. Its output arrives here raw, and each frame's image sequences
-- are written straight to the host terminal with nvim_ui_send(), after moving
-- the host cursor to the window. Everything else dcat writes (alternate
-- screen, clearing, cursor moves) is dropped, since it assumes it owns the
-- whole screen.

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
-- dcat marks the start and end of every frame with synchronized updates
local FRAME_END = "\27[?2026l"
-- Big enough that dcat never crops a frame to it. dcat assumes 10x20 pixel
-- cells when the pty reports no pixel size.
local PTY_COLUMNS, PTY_ROWS = 1000, 500
-- dcat always uses image 1, which other image plugins may use too
local KITTY_IMAGE_ID = 2147483000
-- dcat's request for device attributes, which ends its support queries
local DA1_QUERY = "\27[c"
-- Keys forwarded to dcat. Everything else keeps its normal-mode meaning.
local KEYS = { "w", "a", "s", "d", "e", "r", "m", "p", "1", "2" }

-- Ask dcat to quit with q, so it removes its shared memory objects, and only
-- kill it if it doesn't. Stopping the job outright closes its pty, and the
-- signals that follow can end dcat before it cleans up.
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

-- The host terminal's cell size in pixels. The server's stdio is the TUI's
-- terminal, so it answers the same ioctl the terminal's size comes from.
---@return integer?, integer?
local function cell_pixels()
  ---@type any FFI struct, opaque to the type checker
  local size = ffi.new("struct dcat_winsize")
  for _, fd in ipairs({ 1, 0, 2 }) do
    if ffi.C.ioctl(fd, TIOCGWINSZ, size) == 0 and size.ws_xpixel > 0 and size.ws_col > 0 and size.ws_row > 0 then
      return math.floor(size.ws_xpixel / size.ws_col), math.floor(size.ws_ypixel / size.ws_row)
    end
  end
end

-- Why pixels can't be shown here, or nil if they can
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
end

-- The graphics protocol the terminal supports, judged the way dcat does
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

-- Whether a float's border has a top and a left side, which the window's
-- screen position includes
---@param win integer
---@return integer top, integer left
local function border_offsets(win)
  local border = vim.api.nvim_win_get_config(win).border
  if type(border) ~= "table" or #border == 0 then
    return 0, 0
  end
  -- Sides are listed clockwise from the top left corner. An empty one is left out.
  local function present(index)
    local side = border[(index - 1) % #border + 1]
    side = type(side) == "table" and side[1] or side
    return side ~= "" and 1 or 0
  end
  return present(2), present(8)
end

-- The window's text area on screen: 1-based row and column, size in cells
---@param win integer
---@param mode "kitty"|"sixel"
local function text_area(win, mode)
  local info = vim.fn.getwininfo(win)[1]
  local top, left = border_offsets(win)
  local row = info.winrow + top + (info.winbar or 0)
  local rows = info.height
  -- A Sixel image reaching the bottom row would scroll the screen
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
  local shown = false

  local function hide()
    if not shown then
      return
    end
    shown = false
    if mode == "kitty" then
      vim.api.nvim_ui_send(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(KITTY_IMAGE_ID))
    else
      vim.cmd("redraw!")
    end
  end

  -- The text area size dcat is rendering for
  local size

  local function current_size()
    local _, _, columns, rows = text_area(win, mode)
    return columns .. "x" .. rows
  end

  local function visible()
    return vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  end

  -- Where the image is in dcat's output for one frame, found with plain
  -- searches. Lua patterns are hundreds of times slower on frames this big.
  ---@param output string
  ---@param from integer
  ---@return integer? start, integer? finish, integer? header_end
  local function find_image(output, from)
    if mode == "sixel" then
      -- Sixel data never contains ESC, so the first ST ends it
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
      -- Inline pixels come in chunks, and the last has m=0. Base64 has no
      -- ";", so "m=0;" only appears in a chunk header.
      local last = output:find("m=0;", header_end, true)
      finish = last and select(2, output:find("\27\\", last, true))
    else
      -- A single sequence, like a frame in shared memory
      finish = select(2, output:find("\27\\", header_end, true))
    end
    return start, finish, header_end
  end

  -- dcat counts a shared memory frame as read once the terminal removes it,
  -- and gives up on shared memory if frames go unread. Frames that aren't
  -- shown are removed here instead.
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
  ---@param from integer
  ---@param to integer
  local function show(output, from, to)
    local start, finish, header_end = find_image(output, from)
    if not start or not finish or finish > to then
      return
    end
    local image
    if header_end then
      local header = output:sub(start, header_end):gsub("i=1,p=1", ("i=%d,p=1"):format(KITTY_IMAGE_ID), 1)
      image = header .. output:sub(header_end + 1, finish)
    else
      image = output:sub(start, finish)
    end
    local row, col = text_area(win, mode)
    -- Save the cursor, draw at the window, and put the cursor back where the
    -- TUI left it, all in one synchronized update
    vim.api.nvim_ui_send(("\27[?2026h\0277\27[%d;%dH"):format(row, col) .. image .. "\0278\27[?2026l")
    shown = true
  end

  -- Kitty query ids dcat is waiting on answers for, while it waits
  local query_ids

  -- dcat asks the terminal whether it can read shared memory before its first
  -- frame. Neovim's pty would never answer, so the query goes to the host
  -- terminal, and the TermResponse handler below relays the replies.
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
    -- The device attributes reply comes last
    if sequence:match("^\27%[%?[%d;]*c$") then
      vim.api.nvim_chan_send(job, sequence)
      query_ids = nil
    end
  end

  local probing = false

  local function on_output(id, data)
    -- A stopped dcat can still deliver the rest of a frame, which would be
    -- spliced into the new one's output
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
    -- The end marker may straddle two reads
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

    -- Only the newest frame is shown, so a slow terminal skips frames instead
    -- of falling further behind
    for i = 1, #frames - 1 do
      discard(output, frames[i][1], frames[i][2])
    end
    local newest = frames[#frames]
    -- A frame rendered for an old size would spill out of the window
    if visible() and current_size() == size then
      show(output, newest[1], newest[2])
    else
      discard(output, newest[1], newest[2])
      hide()
    end
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
  end

  start = function()
    local _, _, columns, rows = text_area(win, mode)
    size = columns .. "x" .. rows
    probing = mode == "kitty"
    query_ids = nil
    local full_cmd = vim.list_extend(vim.deepcopy(cmd), {
      mode == "kitty" and "--kitty" or "--sixel",
      "-W",
      tostring(columns * cell_width),
      "-H",
      tostring(rows * cell_height),
      "--",
      path,
    })
    job = vim.fn.jobstart(full_cmd, {
      pty = true,
      width = PTY_COLUMNS,
      height = PTY_ROWS,
      on_stdout = on_output,
      on_exit = function(id, code)
        vim.schedule(function()
          if id ~= job or stopping then
            return
          end
          -- dcat prints errors after restoring the screen, past its last frame
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

  -- nowait, so longer mappings starting with these keys don't delay them
  for _, key in ipairs(KEYS) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_chan_send(job, key)
    end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "q", viewer.close, { buffer = buf, nowait = true })

  -- dcat's render size is fixed by -W and -H, so a new size needs a new dcat.
  -- A window that only moved needs nothing, since every frame is placed anew.
  local restart_timer
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if not visible() then
        return
      end
      if current_size() == size then
        return
      end
      if restart_timer then
        restart_timer:stop()
      end
      restart_timer = vim.defer_fn(function()
        if stopping or not visible() or current_size() == size then
          return
        end
        local old = job
        job = nil
        stop(old)
        chunks = {}
        hide()
        start()
      end, 150)
    end,
  })
  -- Quitting Neovim would otherwise kill dcat before it removes the shared
  -- memory objects for frames still on their way, leaving them in memory
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
