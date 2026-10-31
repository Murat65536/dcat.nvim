-- Character viewer: dcat in a :terminal

local M = {}

local group = vim.api.nvim_create_augroup("dcat_terminal", { clear = true })

local NOT_FORWARDED = { ["<C-C>"] = true, ["<C-W>"] = true, ["<C-\\>"] = true, ["<C-Bslash>"] = true }

-- Keys that go to Neovim instead of dcat
---@param buf integer
local function forward_keys(buf)
  local function map(key, rhs)
    if vim.fn.maparg(key, "t") == "" then
      vim.keymap.set("t", key, rhs, { buffer = buf })
    end
  end

  map("<C-W>", "<C-\\><C-n><C-W>")
  map(":", "<C-\\><C-n>:")

  for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
    local key = mapping.lhs or ""
    if key:match("^<[CMA]%-[^>]+>$") and not NOT_FORWARDED[key] then
      map(key, function()
        -- Fed in terminal mode, the key would trigger this mapping again
        vim.cmd.stopinsert()
        vim.schedule(function()
          vim.api.nvim_feedkeys(vim.keycode(key), "m", false)
        end)
      end)
    end
  end
end

-- Joins lines the terminal wrapped
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
        -- Close first, so cmdheight is back for the message
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
