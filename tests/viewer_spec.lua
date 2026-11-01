local T = ...

local function open()
  T.setup()
  vim.cmd("Dcat model.obj")
  T.wait(function()
    return T.running() == 1
  end, "dcat to start")
end

local function stopped()
  return T.running() == 0
end

T.case("starts dcat in a terminal with a character mode", function()
  open()
  local args = T.starts()[1].args
  T.eq(vim.bo.buftype, "terminal", "viewer buffer")
  assert(
    vim.tbl_contains(args, "--palette-characters") or vim.tbl_contains(args, "--truecolor-characters"),
    "no character mode in " .. vim.inspect(args)
  )
  T.eq(args[#args - 1], "--", "separator before the model")
  T.eq(args[#args], vim.fn.getcwd() .. "/model.obj", "model path")
end)

T.case("an output flag passed to :Dcat replaces the automatic one", function()
  T.setup()
  vim.cmd("Dcat model.obj -B")
  T.wait(function()
    return #T.starts() == 1
  end, "dcat to start")
  local args = T.starts()[1].args
  assert(
    vim.tbl_contains(args, "--block-characters") and not vim.tbl_contains(args, "--palette-characters"),
    vim.inspect(args)
  )
end)

T.case("q and Q don't reach dcat, <C-c> closes the viewer", function()
  open()
  vim.api.nvim_input("qQ")
  T.sleep(300)
  T.eq(T.running(), 1, "dcat running after q and Q")
  vim.api.nvim_input("<C-c>")
  T.wait(stopped, "dcat to quit")
  assert(vim.bo.buftype ~= "terminal", "viewer still shown")
end)

T.case("other keys reach dcat", function()
  open()
  vim.api.nvim_input("m")
  T.wait(function()
    return vim.iter(T.events()):any(function(e)
      return e.event == "key" and e.key == "m"
    end)
  end, "dcat to get m")
end)

T.case("showing another file in the viewer's window stops dcat", function()
  open()
  vim.cmd("edit other.txt")
  T.wait(stopped, "dcat to stop")
  T.eq(T.events()[#T.events()].reason, "q", "how dcat was stopped")
end)

T.case("closing the viewer's window stops dcat", function()
  open()
  local viewer = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.cmd("enew")
  vim.api.nvim_win_close(viewer, false)
  T.wait(stopped, "dcat to stop")
end)

T.case("closing the viewer's tab stops dcat, switching tabs doesn't", function()
  vim.cmd("tabnew")
  open()
  vim.cmd("tabprev")
  T.sleep(300)
  T.eq(T.running(), 1, "dcat running while its tab is in the background")
  vim.cmd("tabnext")
  vim.cmd("tabclose")
  T.wait(stopped, "dcat to stop")
end)

T.case("a killed dcat is reported, not the frame it left", function()
  open()
  vim.uv.kill(T.starts()[1].pid, "sigkill")
  T.wait(function()
    return #T.notes > 0
  end, "a notification")
  T.eq(T.notes[1], "dcat was stopped by signal 9", "notification")
end)

T.case("quitting Neovim lets dcat quit cleanly", {
  after = function(events)
    local last = events[#events]
    assert(last.event == "exit" and last.reason == "q", "dcat didn't quit with q: " .. vim.inspect(last))
  end,
}, open)
