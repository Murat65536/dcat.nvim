-- Each case runs in its own Neovim, as a coroutine, so waiting hands control
-- back to Neovim and typed keys get processed

local T = { cases = {}, notes = {}, sent = {} }

-- opts: tui = { size, cell } to run in a terminal UI, env for the fake dcat,
-- after(events) to check the fake dcat's log once Neovim has exited
function T.case(name, opts, fn)
  if not fn then
    opts, fn = {}, opts
  end
  table.insert(T.cases, { name = name, opts = opts, fn = fn })
end

function T.sleep(ms)
  local co = coroutine.running()
  vim.defer_fn(function()
    T.resume(co)
  end, ms)
  coroutine.yield()
end

function T.wait(condition, what)
  local deadline = vim.uv.now() + 5000
  while not condition() do
    if vim.uv.now() > deadline then
      error("timed out waiting for " .. what, 2)
    end
    T.sleep(20)
  end
end

function T.eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(("%s: expected %s, got %s"):format(what, vim.inspect(want), vim.inspect(got)), 2)
  end
end

-- The fake dcat's log
function T.events()
  local ok, lines = pcall(vim.fn.readfile, vim.env.FAKE_DCAT_LOG)
  return ok and vim.tbl_map(vim.json.decode, lines) or {}
end

function T.starts()
  return vim.tbl_filter(function(event)
    return event.event == "start"
  end, T.events())
end

function T.running()
  return #vim.tbl_filter(function(start)
    return vim.uv.kill(start.pid, 0) == 0
  end, T.starts())
end

function T.setup(opts)
  local fake = { "python3", vim.env.DCAT_TEST_ROOT .. "/tests/fake_dcat.py" }
  require("dcat").setup(vim.tbl_extend("force", { cmd = fake }, opts or {}))
end

-- The newest data sent to the host terminal that contains this text
function T.find_sent(text)
  for i = #T.sent, 1, -1 do
    if T.sent[i]:find(text, 1, true) then
      return T.sent[i]
    end
  end
end

function T.resume(co)
  local ok, err = coroutine.resume(co)
  if not ok or coroutine.status(co) == "dead" then
    vim.fn.writefile({ ok and "ok" or debug.traceback(co, tostring(err)) }, vim.env.DCAT_TEST_RESULT)
    vim.cmd("qa!")
  end
end

function T.run(spec, name)
  loadfile(spec)(T)
  local case = vim.iter(T.cases):find(function(c)
    return c.name == name
  end)
  vim.notify = function(message)
    table.insert(T.notes, message)
  end
  local send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(data)
    table.insert(T.sent, data)
    return send(data)
  end
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = vim.schedule_wrap(function()
      T.resume(coroutine.create(case.fn))
    end),
  })
end

return T
