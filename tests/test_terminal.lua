local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local child = h.new_child()
local run_dir_env

-- Start a child with its own stdpath("run"), a notify recorder and a fake adapter.
local function start()
  run_dir_env = h.tmp_dir()
  local saved = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = run_dir_env
  child.restart({ "-u", "tests/minimal_init.lua" })
  vim.env.XDG_RUNTIME_DIR = saved
  child.lua([[
    _G.notes = {}
    vim.notify = function(msg, level)
      table.insert(_G.notes, { msg = msg, level = level })
    end
    -- Register a fake adapter. `files` are names inside the run dir, or absolute paths.
    _G.fake = function(name, cmd, files, opts)
      require("duet.agents").register({
        name = name,
        cmd = cmd,
        capabilities = { mcp = false, plan_hook = false, system_prompt = false },
        launch = function(self, spec)
          local list = {}
          for _, f in ipairs(files or {}) do
            local path = vim.startswith(f, "/") and f or vim.fs.joinpath(spec.run_dir, f)
            list[#list + 1] = { path = path, content = "content of " .. f }
          end
          return { argv = vim.deepcopy(self.cmd), env = { FAKE = "1" }, files = list }
        end,
      })
      require("duet").setup(vim.tbl_deep_extend("force", { agent = name }, opts or {}))
    end
    _G.T = require("duet.terminal")
    _G.wait = function(fn, ms)
      return vim.wait(ms or 3000, fn, 10)
    end
    -- The terminal's text with lines joined, so wrapped output reads as one line.
    _G.text = function(id)
      return table.concat(vim.api.nvim_buf_get_lines(T.get(id).buf, 0, -1, false), "")
    end
    _G.running = function(job)
      return vim.fn.jobwait({ job }, 0)[1] == -1
    end
    -- Names of the entries in the run root, sorted.
    _G.run_entries = function()
      local entries = {}
      for name in vim.fs.dir(T.run_root()) do
        entries[#entries + 1] = name
      end
      table.sort(entries)
      return entries
    end
  ]])
end

local function fake(name, cmd, files, opts)
  child.lua("_G.fake(...)", { name, cmd, files or {}, opts or {} })
end

local CAT = { "sh", "-c", "cat" }

local T = MiniTest.new_set({
  hooks = {
    pre_case = start,
    post_once = child.stop,
  },
})

T["session"] = MiniTest.new_set()

T["session"]["opens, hides and shows; the job survives hiding"] = function()
  fake("fake", CAT)
  local info = child.lua([[
    local s = assert(T.open())
    local win = s:window()
    return {
      id = s.id, buf = s.buf, job = s.job, visible = s:is_visible(),
      float = vim.api.nvim_win_get_config(win).relative,
      current = vim.api.nvim_get_current_win() == win,
      buftype = vim.bo[s.buf].buftype, filetype = vim.bo[s.buf].filetype,
      var = vim.b[s.buf].duet_session, name = vim.api.nvim_buf_get_name(s.buf),
      bufhidden = vim.bo[s.buf].bufhidden, listed = vim.bo[s.buf].buflisted,
    }
  ]])
  eq(info.visible, true)
  eq(info.float, "editor")
  eq(info.current, true)
  eq(info.buftype, "terminal")
  eq(info.filetype, "duet_terminal")
  eq(info.var, info.id)
  eq(info.name, "duet://fake/" .. info.id)
  eq({ info.bufhidden, info.listed }, { "hide", false })

  child.lua("T.get(...):hide()", { info.id })
  eq(child.lua_get("T.get(...):is_visible()", { info.id }), false)
  eq(child.lua_get("running(...)", { info.job }), true)
  eq(child.lua_get("vim.api.nvim_buf_is_valid(...)", { info.buf }), true)

  child.lua("T.get(...):show()", { info.id })
  eq(child.lua_get("T.get(...):is_visible()", { info.id }), true)
  eq(child.lua_get("{ T.get(...).buf, T.get(...).job }", { info.id }), { info.buf, info.job })
  eq(child.lua_get("running(...)", { info.job }), true)
end

T["session"]["keeps the terminal content across hide and show"] = function()
  fake("fake", { "sh", "-c", "echo hello-from-agent; cat" })
  local id = child.lua_get("T.open().id")
  eq(
    child.lua(
      "local id = ...; return wait(function() return text(id):find('hello-from-agent', 1, true) ~= nil end)",
      { id }
    ),
    true
  )
  child.lua("T.get(...):hide(); T.get(...):show()", { id })
  eq(child.lua_get("text(...):find('hello-from-agent', 1, true) ~= nil", { id }), true)
end

T["session"]["sets $NVIM to the parent's servername"] = function()
  fake("fake", { "sh", "-c", [[echo "<NVIM=$NVIM FAKE=$FAKE>"; cat]] })
  local id = child.lua_get("T.open().id")
  local found = child.lua(
    [[local id = ...
    local found
    wait(function()
      found = text(id):match("<NVIM=.->")
      return found ~= nil
    end)
    return found]],
    { id }
  )
  local servername = child.v.servername
  eq(servername ~= "", true)
  eq(found, ("<NVIM=%s FAKE=1>"):format(servername))
end

T["session"]["starts a server when Neovim has none"] = function()
  -- A headless --clean Neovim has an empty v:servername until something starts a server.
  local out_file = vim.fs.joinpath(h.tmp_dir(), "out.txt")
  local script = vim.fs.joinpath(h.tmp_dir(), "script.lua")
  vim.fn.writefile({
    "vim.opt.rtp:prepend(vim.fn.getcwd())",
    "for _, addr in ipairs(vim.fn.serverlist()) do vim.fn.serverstop(addr) end",
    "local before = vim.v.servername",
    "require('duet.agents').register({ name = 'fake', cmd = { 'sh', '-c', 'echo \"<NVIM=$NVIM>\"; cat' },",
    "  capabilities = { mcp = false, plan_hook = false, system_prompt = false },",
    "  launch = function(self) return { argv = self.cmd, env = {}, files = {} } end })",
    "local s = assert(require('duet.terminal').open('fake'))",
    "local line",
    "vim.wait(3000, function()",
    "  line = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), ''):match('<NVIM=.->')",
    "  return line ~= nil",
    "end)",
    "vim.fn.writefile({ before, vim.v.servername, line or '' }, " .. vim.inspect(out_file) .. ")",
    "require('duet.terminal').stop_all()",
  }, script)
  h.run({ vim.v.progpath, "--headless", "--clean", "-l", script })
  local out = vim.fn.readfile(out_file)
  eq(out[1], "")
  eq(out[2] ~= "", true)
  eq(out[3], "<NVIM=" .. out[2] .. ">")
end

T["session"]["writes the plan's files with mode 0600"] = function()
  fake("fake", CAT, { "mcp.json", "sub/settings.json" })
  local info = child.lua([[
    local s = assert(T.open())
    local file = vim.fs.joinpath(s.run_dir, "mcp.json")
    return {
      under_root = vim.fs.dirname(s.run_dir) == T.run_root(),
      dir_mode = vim.uv.fs_stat(s.run_dir).mode % 512,
      file_mode = vim.uv.fs_stat(file).mode % 512,
      content = vim.fn.readfile(file),
      nested = vim.uv.fs_stat(vim.fs.joinpath(s.run_dir, "sub/settings.json")) ~= nil,
    }
  ]])
  eq(info.under_root, true)
  eq(info.dir_mode, tonumber("700", 8))
  eq(info.file_mode, tonumber("600", 8))
  eq(info.content, { "content of mcp.json" })
  eq(info.nested, true)
end

T["session"]["removes the run dir and notifies when the job exits"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; exit 3" }, { "mcp.json" })
  local info = child.lua([[
    local s = assert(T.open())
    local existed = vim.uv.fs_stat(s.run_dir) ~= nil
    wait(function() return s.exit_code ~= nil end)
    return {
      existed = existed, exists = vim.uv.fs_stat(s.run_dir) ~= nil, code = s.exit_code,
      buf_valid = vim.api.nvim_buf_is_valid(s.buf), listed = T.get(s.id) ~= nil,
    }
  ]])
  eq(info.existed, true)
  eq(info.exists, false)
  eq(info.code, 3)
  -- The buffer stays until the user closes it.
  eq(info.buf_valid, true)
  eq(info.listed, true)
  eq(child.lua_get("_G.notes"), { { msg = "[duet] fake exited with code 3", level = vim.log.levels.WARN } })
end

T["session"]["wipes the buffer on exit with close_on_exit"] = function()
  fake("fake", { "sh", "-c", "exit 0" }, {}, { terminal = { close_on_exit = true } })
  local info = child.lua([[
    local s = assert(T.open())
    wait(function() return not vim.api.nvim_buf_is_valid(s.buf) end)
    return { buf_valid = vim.api.nvim_buf_is_valid(s.buf), listed = T.get(s.id) ~= nil }
  ]])
  eq(info, { buf_valid = false, listed = false })
  eq(child.lua_get("run_entries()"), {})
end

T["session"]["rejects files outside the run dir"] = function()
  local outside = vim.fs.joinpath(h.tmp_dir(), "evil.json")
  fake("fake", CAT, { outside })
  local result = child.lua("return { T.open() }")
  eq(result[1], vim.NIL)
  eq(result[2]:match("outside the run dir") ~= nil, true)
  eq(vim.uv.fs_stat(outside), nil)
  eq(child.lua_get("#T.list()"), 0)
  eq(child.lua_get("vim.uv.fs_stat(T.run_root()) == nil or #run_entries() == 0"), true)
end

T["session"]["reports a missing binary and cleans up"] = function()
  fake("fake", { "duet-no-such-binary" }, { "mcp.json" })
  local wins = child.lua_get("#vim.api.nvim_list_wins()")
  local result = child.lua("return { T.open() }")
  eq(result[1], vim.NIL)
  eq(result[2]:match("^terminal: cannot start fake") ~= nil, true)
  eq(child.lua_get("#T.list()"), 0)
  eq(child.lua_get("run_entries()"), {})
  eq(child.lua_get("#vim.api.nvim_list_wins()"), wins)
end

T["session"]["reports an adapter whose launch throws"] = function()
  child.lua([[
    require("duet.agents").register({
      name = "broken", cmd = { "sh" },
      capabilities = { mcp = false, plan_hook = false, system_prompt = false },
      launch = function() error("boom") end,
    })
  ]])
  local result = child.lua("return { T.open('broken') }")
  eq(result[1], vim.NIL)
  eq(result[2]:match("^terminal: broken launch failed: .*boom") ~= nil, true)
end

T["session"]["maps <C-q> to leave terminal mode"] = function()
  fake("fake", CAT)
  local map = child.lua([[
    local s = T.open()
    return vim.api.nvim_buf_call(s.buf, function() return vim.fn.maparg("<C-q>", "t", false, true) end)
  ]])
  eq(map.buffer, 1)
  eq(map.rhs, [[<C-\><C-n>]])
end

T["session"]["uses configured keys"] = function()
  fake("fake", CAT, {}, { terminal = { keys = { ["<C-q>"] = false, ["<C-x>"] = "hide" } } })
  local maps = child.lua([[
    local s = T.open()
    return vim.api.nvim_buf_call(s.buf, function()
      return { vim.fn.maparg("<C-q>", "t"), vim.fn.maparg("<C-x>", "t", false, true).buffer }
    end)
  ]])
  eq(maps, { "", 1 })
end

T["session"]["restart starts a new session in the same window"] = function()
  fake("fake", CAT, { "mcp.json" })
  local old = child.lua("local s = T.open(); return { id = s.id, win = s:window(), buf = s.buf, dir = s.run_dir }")
  local new = child.lua("local s = assert(T.restart()); return { id = s.id, win = s:window(), job = s.job }")
  eq(new.id ~= old.id, true)
  eq(new.win, old.win)
  eq(child.lua_get("running(...)", { new.job }), true)
  eq(child.lua_get("vim.api.nvim_buf_is_valid(...)", { old.buf }), false)
  eq(child.lua_get("vim.uv.fs_stat(...) == nil", { old.dir }), true)
  eq(child.lua_get("T.get(...) == nil", { old.id }), true)
  child.lua("vim.wait(100)")
  eq(child.lua_get("_G.notes"), {})
end

T["session"]["opening an exited session restarts it"] = function()
  fake("fake", { "sh", "-c", "exit 0" })
  local old = child.lua([[
    local s = T.open()
    wait(function() return s.exit_code ~= nil end)
    s:hide()
    return s.id
  ]])
  local new = child.lua_get("T.open().id")
  eq(new ~= old, true)
  eq(child.lua_get("T.get(...) == nil", { old }), true)
end

T["session"]["showing one session hides the other"] = function()
  fake("one", CAT)
  fake("two", CAT)
  local a = child.lua_get("T.open('one').id")
  local b = child.lua_get("T.open('two').id")
  eq(child.lua_get("T.get(...):is_visible()", { a }), false)
  eq(child.lua_get("T.get(...):is_visible()", { b }), true)
end

T["session"]["stop_all stops jobs and removes run dirs on VimLeavePre"] = function()
  fake("fake", CAT, { "mcp.json" })
  local job = child.lua_get("T.open().job")
  child.cmd("doautocmd VimLeavePre")
  eq(child.lua("local job = ...; return wait(function() return not running(job) end)", { job }), true)
  eq(child.lua_get("run_entries()"), {})
  eq(child.lua_get("#T.list()"), 0)
end

T["session"]["stop_all stops every session"] = function()
  fake("one", CAT, { "mcp.json" })
  fake("two", CAT, { "mcp.json" })
  fake("three", CAT, { "mcp.json" })
  local jobs = child.lua("return { T.open('one').job, T.open('two').job, T.open('three').job }")
  eq(#child.lua_get("run_entries()"), 3)
  child.cmd("doautocmd VimLeavePre")
  eq(
    child.lua(
      [[local jobs = ...
      return wait(function()
        return not (running(jobs[1]) or running(jobs[2]) or running(jobs[3]))
      end)]],
      { jobs }
    ),
    true
  )
  eq(child.lua_get("run_entries()"), {})
  eq(child.lua_get("#T.list()"), 0)
end

T["session"]["wiping the buffer forgets the session"] = function()
  fake("fake", CAT, { "mcp.json" })
  local s = child.lua("local s = T.open(); return { id = s.id, buf = s.buf, job = s.job }")
  child.cmd("bwipeout! " .. s.buf)
  eq(child.lua_get("T.get(...) == nil", { s.id }), true)
  eq(child.lua("local job = ...; return wait(function() return not running(job) end)", { s.job }), true)
  eq(child.lua_get("run_entries()"), {})
  child.lua("vim.wait(100)")
  eq(child.lua_get("_G.notes"), {})
end

T["current()"] = MiniTest.new_set()

T["current()"]["follows the project root"] = function()
  fake("fake", CAT)
  local a, b = h.tmp_dir(), h.tmp_dir()
  child.cmd("cd " .. a)
  local id_a = child.lua_get("T.open().id")
  eq(child.lua_get("T.get(...).root", { id_a }), a)
  child.lua("T.get(...):hide()", { id_a })
  child.cmd("cd " .. b)
  eq(child.lua_get("T.current() == nil"), true)
  child.cmd("cd " .. a)
  eq(child.lua_get("T.current().id"), id_a)
end

T["current()"]["uses the git root"] = function()
  local repo = h.tmp_git_repo({ ["sub/file.txt"] = "x" })
  fake("fake", CAT)
  child.cmd("cd " .. vim.fs.joinpath(repo, "sub"))
  eq(child.lua_get("T.open().root"), repo)
end

T["current()"]["prefers the session in the current buffer, then the most recent"] = function()
  fake("one", CAT)
  fake("two", CAT)
  local a = child.lua_get("T.open('one').id")
  local b = child.lua_get("T.open('two').id")
  child.cmd("wincmd p")
  eq(child.lua_get("T.current().id"), b)
  child.lua("T.get(...):focus()", { a })
  eq(child.lua_get("T.current().id"), a)
end

T["commands"] = MiniTest.new_set()

T["commands"][":Duet toggles the same session"] = function()
  fake("fake", CAT)
  child.cmd("Duet")
  local id = child.lua_get("T.current().id")
  eq(child.lua_get("T.current():is_visible()"), true)
  child.cmd("Duet")
  eq(child.lua_get("T.current():is_visible()"), false)
  child.cmd("Duet toggle")
  eq(child.lua_get("T.current().id"), id)
  eq(child.lua_get("T.current():is_visible()"), true)
end

T["commands"][":Duet open, close and :Duet! close"] = function()
  fake("fake", CAT, { "mcp.json" })
  fake("other", CAT)
  child.cmd("Duet open fake")
  local s = child.lua("local s = T.current(); return { id = s.id, job = s.job, name = s.agent.name }")
  eq(s.name, "fake")
  child.cmd("Duet close")
  eq(child.lua_get("T.get(...):is_visible()", { s.id }), false)
  eq(child.lua_get("running(...)", { s.job }), true)
  child.cmd("Duet! close")
  eq(child.lua_get("#T.list()"), 0)
  eq(child.lua_get("run_entries()"), {})
end

T["commands"][":Duet restart"] = function()
  fake("fake", CAT)
  child.cmd("Duet restart")
  local first = child.lua_get("T.current().id")
  child.cmd("Duet restart")
  local second = child.lua_get("T.current().id")
  eq(first ~= second, true)
  eq(child.lua_get("#T.list()"), 1)
end

T["commands"]["reports an unknown agent"] = function()
  fake("fake", CAT)
  child.cmd("Duet open nope")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(notes[1].msg:match("unknown agent 'nope'") ~= nil, true)
  eq(notes[1].level, vim.log.levels.ERROR)
end

T["commands"]["complete agent names"] = function()
  fake("fake", CAT)
  eq(child.fn.getcompletion("Duet open f", "cmdline"), { "fake" })
  eq(child.fn.getcompletion("Duet toggle fake ", "cmdline"), {})
end

T["layout"] = MiniTest.new_set()

T["layout"]["opens a split"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "right", split = { width = 30 } } })
  local info = child.lua([[
    local s = T.open()
    local win = s:window()
    return {
      relative = vim.api.nvim_win_get_config(win).relative,
      width = vim.api.nvim_win_get_width(win),
      col = vim.api.nvim_win_get_position(win)[2],
      fix = vim.wo[win].winfixwidth, number = vim.wo[win].number,
    }
  ]])
  eq(info.relative, "")
  eq(info.width, 30)
  eq(info.col > 0, true)
  eq({ info.fix, info.number }, { true, false })
end

T["layout"]["hides a split that is the last window"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "bottom" } })
  local info = child.lua([[
    local s = T.open()
    vim.cmd("only")
    s:hide()
    return { visible = s:is_visible(), running = running(s.job), wins = #vim.api.nvim_list_wins() }
  ]])
  eq(info, { visible = false, running = true, wins = 1 })
end

local OPTS = {
  float = { width = 0.5, height = 0.5, border = "rounded" },
  split = { width = 0.4, height = 10 },
}

local geometry_cases = {
  {
    name = "float centred with border",
    layout = "float",
    opts = OPTS,
    expected = {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = 49,
      height = 19,
      row = 9,
      col = 24,
      title = " t ",
      title_pos = "center",
    },
  },
  {
    name = "float without border has no title",
    layout = "float",
    opts = { float = { width = 1, height = 1, border = "none" }, split = OPTS.split },
    expected = { relative = "editor", style = "minimal", border = "none", width = 100, height = 40, row = 0, col = 0 },
  },
  {
    name = "float absolute size is clamped",
    layout = "float",
    opts = { float = { width = 500, height = 30, border = "single" }, split = OPTS.split },
    expected = {
      relative = "editor",
      style = "minimal",
      border = "single",
      width = 98,
      height = 30,
      row = 4,
      col = 0,
      title = " t ",
      title_pos = "center",
    },
  },
  {
    name = "right split, fraction",
    layout = "right",
    opts = OPTS,
    expected = { split = "right", win = -1, width = 40 },
  },
  { name = "left split", layout = "left", opts = OPTS, expected = { split = "left", win = -1, width = 40 } },
  {
    name = "bottom split, absolute",
    layout = "bottom",
    opts = OPTS,
    expected = { split = "below", win = -1, height = 10 },
  },
}

T["win_config()"] = MiniTest.new_set()
for _, case in ipairs(geometry_cases) do
  T["win_config()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").win_config(case.layout, case.opts, 100, 40, " t "), case.expected)
  end
end

local size_cases = {
  { name = "fraction", value = 0.5, total = 81, expected = 40 },
  { name = "one is the whole", value = 1, total = 80, expected = 80 },
  { name = "absolute", value = 30, total = 80, expected = 30 },
  { name = "absolute clamped", value = 300, total = 80, expected = 80 },
  { name = "tiny fraction is at least 1", value = 0.001, total = 80, expected = 1 },
}

T["resolve_size()"] = MiniTest.new_set()
for _, case in ipairs(size_cases) do
  T["resolve_size()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").resolve_size(case.value, case.total), case.expected)
  end
end

return T
