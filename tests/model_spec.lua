local T = ...

local function edit_model()
  T.setup()
  vim.cmd("edit model.obj")
  T.wait(function()
    return vim.bo.buftype == "terminal" and T.running() == 1
  end, "the viewer")
end

local function close_viewer()
  vim.api.nvim_input("<C-c>")
  T.wait(function()
    return T.running() == 0 and vim.bo.buftype == "nofile"
  end, "the placeholder")
end

T.case("editing a model opens the viewer over an empty placeholder", function()
  edit_model()
  close_viewer()
  T.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" }, "placeholder lines")
  T.eq(vim.bo.filetype, "dcat", "placeholder filetype")
  assert(not pcall(vim.cmd.write), ":w wrote the placeholder over the model")
end)

T.case("closing the viewer doesn't open it again", function()
  edit_model()
  close_viewer()
  T.sleep(500)
  T.eq(#T.starts(), 1, "dcat starts")
end)

T.case("showing the model's buffer again reopens the viewer", function()
  edit_model()
  local viewer = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.cmd("enew")
  vim.api.nvim_win_close(viewer, false)
  T.wait(function()
    return T.running() == 0
  end, "dcat to stop")
  vim.cmd("edit model.obj")
  T.wait(function()
    return #T.starts() == 2 and vim.bo.buftype == "terminal"
  end, "the viewer to reopen")
end)

T.case("e edits the model as text", function()
  edit_model()
  close_viewer()
  vim.api.nvim_feedkeys("e", "x", false)
  T.eq(vim.bo.buftype, "", "buftype")
  T.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "v 0 0 0" }, "lines")
  vim.cmd("enew")
  vim.cmd("buffer model.obj")
  T.sleep(300)
  T.eq(#T.starts(), 1, "dcat starts after showing the text again")
end)

T.case("a model dcat can't read shows its error once", function()
  T.setup()
  vim.cmd("edit broken.obj")
  T.wait(function()
    return #T.notes > 0
  end, "the error")
  T.sleep(500)
  assert(T.notes[1]:find("No suitable reader", 1, true), T.notes[1])
  T.eq(#T.starts(), 1, "dcat starts")
end)

T.case("new model files open as text", function()
  T.setup()
  vim.cmd("edit new.obj")
  T.sleep(300)
  T.eq(vim.bo.buftype, "", "buftype")
  T.eq(#T.starts(), 0, "dcat starts")
end)

T.case("files sharing an extension with models open normally", function()
  T.setup()
  vim.fn.writefile({ "AC_INIT([x], [1])" }, "configure.ac")
  vim.cmd("edit configure.ac")
  T.sleep(300)
  T.eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "AC_INIT([x], [1])", "first line")
  T.eq(#T.starts(), 0, "dcat starts")
end)
