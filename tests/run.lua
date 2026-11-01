-- Runs the tests: nvim -l tests/run.lua [part of a test name]

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local env = vim.fn.environ()
-- Tests behave the same inside tmux or a Neovim terminal
env.TMUX, env.STY, env.NVIM = nil, nil, nil
env.DCAT_TEST_ROOT = root

local passed, failed = 0, 0
for _, spec in ipairs(vim.fn.glob(root .. "/tests/*_spec.lua", false, true)) do
  local T = dofile(root .. "/tests/helpers.lua")
  loadfile(spec)(T)
  for _, case in ipairs(T.cases) do
    if not arg[1] or case.name:find(arg[1], 1, true) then
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "v 0 0 0" }, dir .. "/model.obj")
      vim.fn.writefile({ "not a model" }, dir .. "/broken.obj")
      vim.fn.writefile({ "text" }, dir .. "/other.txt")

      local cmd = { "nvim", "--headless", "--clean", "-u", root .. "/tests/init.lua" }
      if case.opts.tui then
        table.remove(cmd, 2)
        cmd = vim.list_extend({ "python3", root .. "/tests/tui.py" }, cmd)
      end
      local case_env = vim.tbl_extend("force", env, case.opts.env or {}, {
        DCAT_TEST_SPEC = spec,
        DCAT_TEST_CASE = case.name,
        DCAT_TEST_RESULT = dir .. "/result",
        FAKE_DCAT_LOG = dir .. "/dcat.log",
      })
      vim.system(cmd, { cwd = dir, env = case_env, clear_env = true }):wait(30000)

      local ok, lines = pcall(vim.fn.readfile, dir .. "/result")
      local result = ok and table.concat(lines, "\n") or "timed out"
      if result == "ok" and case.opts.after then
        local after_ok, err = pcall(case.opts.after, vim.tbl_map(vim.json.decode, vim.fn.readfile(dir .. "/dcat.log")))
        result = after_ok and "ok" or tostring(err)
      end
      if result == "ok" then
        passed = passed + 1
        io.write("ok    " .. case.name .. "\n")
      else
        failed = failed + 1
        io.write("FAIL  " .. case.name .. "\n      " .. result:gsub("\n", "\n      ") .. "\n")
      end
      vim.fn.delete(dir, "rf")
    end
  end
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
