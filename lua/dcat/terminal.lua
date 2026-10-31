-- The character viewer: dcat in a :terminal, drawing with text characters

local M = {}

local group = vim.api.nvim_create_augroup("dcat_terminal", { clear = true })

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

--- Run dcat in the viewer's window
---@param viewer dcat.Viewer
---@param cmd string[] The whole dcat command line
function M.start(viewer, cmd)
  local buf, win = viewer.buf, viewer.win
  local ok, job = pcall(vim.fn.jobstart, cmd, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function()
        local message
        if code ~= 0 and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win) then
          message = terminal_text(buf, vim.api.nvim_win_get_width(win))
          message = message ~= "" and message or ("dcat exited with code " .. code)
        end
        -- Close first, so a fullscreen viewer's message shows with the command line back
        viewer.close()
        if message then
          vim.notify(message, vim.log.levels.ERROR)
        end
      end)
    end,
  })
  if not ok or job <= 0 then
    viewer.close()
    vim.notify("dcat: failed to start " .. cmd[1] .. (ok and "" or (": " .. job)), vim.log.levels.ERROR)
    return
  end

  forward_keys(buf)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    command = "startinsert",
  })
  vim.cmd.startinsert()
end

return M
