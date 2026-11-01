local T = ...

local KITTY = { tui = true, env = { FAKE_DCAT_OUTPUT = "kitty" } }

-- Where an image drawn over the window should start, as the cursor move before it
local function position(win)
  win = win or vim.api.nvim_get_current_win()
  local info = vim.fn.getwininfo(win)[1]
  local border = vim.api.nvim_win_get_config(win).border
  local offset = type(border) == "table" and #border > 0 and 1 or 0
  return ("\27[%d;%dH"):format(info.winrow + offset, info.wincol + offset + info.textoff)
end

local function open(cmd)
  T.setup()
  vim.cmd(cmd or "Dcat model.obj")
  T.wait(function()
    return T.find_sent("\27_Ga=T")
  end, "a Kitty frame")
end

T.case("detection picks pixels in a graphical terminal", KITTY, function()
  T.setup()
  T.eq(require("dcat").output({}), "kitty", "output")
end)

T.case(
  "an old dcat gets characters",
  { tui = true, env = { FAKE_DCAT_OUTPUT = "kitty", FAKE_DCAT_VERSION = "1.3.1" } },
  function()
    T.setup()
    local output, reason = require("dcat").output({})
    assert(output ~= "kitty", "pixels with dcat 1.3.1")
    T.eq(reason, "pixels in Neovim need dcat 1.4.0 or newer", "reason")
  end
)

T.case("Kitty frames are drawn over the viewer's window", KITTY, function()
  vim.cmd("vsplit")
  vim.cmd("wincmd l")
  open()
  local frame = T.find_sent("\27_Ga=T")
  assert(frame:find(position(), 1, true), "frame not at the window: " .. vim.inspect(frame:sub(1, 40)))
  assert(frame:find("i=2147483000", 1, true), "frame without the plugin's image id")
  local args = T.starts()[1].args
  for _, flag in ipairs({ "--kitty", "--cell-size", "10x20", "--kitty-shared-memory" }) do
    assert(vim.tbl_contains(args, flag), flag .. " missing from " .. vim.inspect(args))
  end
end)

T.case("frames are drawn inside a float's border", KITTY, function()
  T.setup()
  require("dcat").open("model.obj", { layout = "float" })
  T.wait(function()
    return T.find_sent("\27_Ga=T")
  end, "a Kitty frame")
  assert(T.find_sent("\27_Ga=T"):find(position(), 1, true), "frame not inside the border")
end)

T.case("resizing keeps the same dcat and its frames follow", KITTY, function()
  vim.cmd("vsplit")
  open()
  vim.api.nvim_win_set_width(0, 30)
  T.wait(function()
    return T.find_sent("s=300,")
  end, "a 300 pixel wide frame")
  T.eq(#T.starts(), 1, "dcat starts")
end)

T.case(
  "frames too big for the window aren't drawn",
  { tui = true, env = { FAKE_DCAT_OUTPUT = "kitty", FAKE_DCAT_FIXED_SIZE = "1" } },
  function()
    open()
    local count = #T.sent
    vim.cmd("vsplit")
    vim.cmd("enew")
    T.wait(function()
      return T.find_sent("a=d,d=i")
    end, "the image to be hidden")
    T.sleep(300)
    for i = count + 1, #T.sent do
      assert(not T.sent[i]:find("\27_Ga=T"), "drew a frame after the window shrank: " .. T.sent[i]:sub(1, 60))
    end
  end
)

T.case("switching tabs hides the image and puts it back", KITTY, function()
  -- A tabline appearing would resize the viewer, and dcat would redraw anyway
  vim.o.showtabline = 2
  open()
  vim.cmd("tabnew")
  T.wait(function()
    return T.find_sent("a=d,d=i")
  end, "the image to be hidden")
  vim.cmd("tabprev")
  T.wait(function()
    return T.find_sent("a=p,")
  end, "the image to be placed again")
end)

T.case("closing deletes the image", KITTY, function()
  open()
  vim.api.nvim_input("<C-c>")
  T.wait(function()
    return T.find_sent("a=d,d=I")
  end, "the image to be deleted")
end)

T.case("Sixel terminals get Sixel frames", { tui = true, env = { FAKE_DCAT_OUTPUT = "sixel" } }, function()
  T.setup()
  vim.cmd("Dcat model.obj")
  T.wait(function()
    return T.find_sent("\27Pq")
  end, "a Sixel frame")
  assert(vim.tbl_contains(T.starts()[1].args, "--sixel"), "no --sixel")
end)
