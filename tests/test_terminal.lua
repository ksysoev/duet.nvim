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
  -- Wide enough for the default 80-column panel next to a code window.
  child.o.columns, child.o.lines = 200, 50
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

-- The child's mode once it settles. A mode change (startinsert, stopinsert) takes effect
-- when the child is back in its main loop, after the call that asked for it returns, and
-- nvim_get_mode() answers at once, so poll from here instead of reading it once.
local function mode_becomes(want)
  local mode
  vim.wait(2000, function()
    mode = child.api.nvim_get_mode().mode
    return mode == want
  end, 10)
  return mode
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = start,
    post_once = child.stop,
  },
})

T["session"] = MiniTest.new_set()

T["session"]["opens, hides and shows; the job survives hiding"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "float" } })
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

T["session"]["removes the run dir and keeps the terminal after an error exit"] = function()
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
  eq(child.lua_get("_G.notes"), {
    {
      msg = "[duet] fake exited with code 3: see the terminal output\nIn the terminal, press i to restart the agent or q to close it.",
      level = vim.log.levels.ERROR,
    },
  })
end

T["exit"] = MiniTest.new_set()

T["exit"]["a clean exit closes the terminal quietly"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; exit 0" })
  local info = child.lua([[
    local code_win = vim.api.nvim_get_current_win()
    local s = assert(T.open())
    local win = s:window()
    wait(function() return not vim.api.nvim_buf_is_valid(s.buf) end)
    return {
      buf_valid = vim.api.nvim_buf_is_valid(s.buf), win_valid = vim.api.nvim_win_is_valid(win),
      listed = T.get(s.id) ~= nil, current = T.current() ~= nil,
      back = vim.api.nvim_get_current_win() == code_win, id = s.id,
    }
  ]])
  eq(info.buf_valid, false)
  eq(info.win_valid, false)
  eq({ info.listed, info.current }, { false, false })
  eq(info.back, true)
  eq(child.lua_get("_G.notes"), {})
  eq(child.lua_get("run_entries()"), {})
  -- The next :Duet starts a new session.
  child.cmd("Duet")
  eq(child.lua_get("T.current() ~= nil and T.current().id ~= ...", { info.id }), true)
end

T["exit"]["a clean exit closes the panel even when wiping would keep the window"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; exit 0" })
  local info = child.lua([[
    -- When autocommands stop the current window from closing (as a snacks.nvim dashboard
    -- next to it does with a UI attached), :bwipeout puts an empty buffer in the window
    -- and keeps it. Emulate that.
    local delete = vim.api.nvim_buf_delete
    vim.api.nvim_buf_delete = function(buf, opts)
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
      return delete(buf, opts)
    end
    local s = assert(T.open())
    local win = s:window()
    wait(function() return not vim.api.nvim_buf_is_valid(s.buf) end)
    vim.api.nvim_buf_delete = delete
    return { win_valid = vim.api.nvim_win_is_valid(win), wins = #vim.api.nvim_tabpage_list_wins(0) }
  ]])
  eq(info, { win_valid = false, wins = 1 })
end

T["exit"]["a clean exit in the last window leaves a normal buffer there"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; exit 0" })
  local info = child.lua([[
    local s = assert(T.open())
    vim.cmd("only")
    local win = s:window()
    wait(function() return not vim.api.nvim_buf_is_valid(s.buf) end)
    local buf = vim.api.nvim_win_get_buf(win)
    return { win_valid = vim.api.nvim_win_is_valid(win), buftype = vim.bo[buf].buftype, listed = T.get(s.id) ~= nil }
  ]])
  eq(info, { win_valid = true, buftype = "", listed = false })
end

T["exit"]["an error exit keeps the window and reports the last output"] = function()
  fake("fake", { "sh", "-c", "read _; echo one; echo; echo 'boom   '; exit 3" })
  child.lua("_G.s = assert(T.open()); _G.win = s:window()")
  eq(mode_becomes("t"), "t")
  child.type_keys("<CR>")
  child.lua("wait(function() return s.exit_code ~= nil end)")
  local info = child.lua_get("{ shown = s:window() == win, listed = T.get(s.id) ~= nil, running = s:is_running() }")
  eq(info, { shown = true, listed = true, running = false })
  -- Terminal mode is left, so the next key does not close the exited terminal.
  eq(mode_becomes("nt"), "nt")
  child.type_keys("k")
  eq(child.lua_get("vim.api.nvim_buf_is_valid(s.buf) and s:window() == win"), true)
  eq(child.lua_get("_G.notes"), {
    {
      msg = "[duet] fake exited with code 3: see the terminal output\none\nboom\nIn the terminal, press i to restart the agent or q to close it.",
      level = vim.log.levels.ERROR,
    },
  })
end

T["exit"]["q closes an exited terminal"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; exit 3" })
  local info = child.lua([[
    local code = vim.api.nvim_get_current_win()
    _G.s = assert(T.open())
    _G.win = s:window()
    wait(function() return s.exit_code ~= nil end)
    return { code = code }
  ]])
  child.type_keys("q")
  eq(
    child.lua_get([[{
      win = vim.api.nvim_win_is_valid(win), buf = vim.api.nvim_buf_is_valid(s.buf), listed = T.get(s.id) ~= nil,
      wins = #vim.api.nvim_tabpage_list_wins(0), current = vim.api.nvim_get_current_win(),
    }]]),
    { win = false, buf = false, listed = false, wins = 1, current = info.code }
  )
  eq(#child.lua_get("_G.notes"), 1)
end

T["exit"]["i or a restarts an exited agent in the same window"] = MiniTest.new_set({
  parametrize = { { "i" }, { "a" } },
})

T["exit"]["i or a restarts an exited agent in the same window"]["%s"] = function(key)
  fake("fake", { "sh", "-c", "sleep 0.2; exit 3" })
  child.lua([[
    _G.s = assert(T.open())
    _G.win = s:window()
    wait(function() return s.exit_code ~= nil end)
  ]])
  eq(mode_becomes("nt"), "nt")
  child.type_keys(key)
  child.lua("wait(function() return T.current() ~= nil and T.current() ~= s end)")
  local info = child.lua_get([[{
    old = T.get(s.id) ~= nil, same_win = T.current():window() == win,
    running = T.current():is_running(), current = vim.api.nvim_get_current_win() == win,
  }]])
  eq(info, { old = false, same_win = true, running = true, current = true })
  eq(mode_becomes("t"), "t")
end

T["exit"]["entering terminal mode another way keeps the exited terminal"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; exit 3" })
  child.lua([[
    _G.s = assert(T.open())
    _G.win = s:window()
    wait(function() return s.exit_code ~= nil end)
  ]])
  child.cmd("startinsert")
  child.type_keys("j")
  eq(mode_becomes("nt"), "nt")
  eq(
    child.lua_get("{ T.current() == s, vim.api.nvim_win_get_buf(win) == s.buf, s:is_running() }"),
    { true, true, false }
  )
end

T["exit"]["a terminal shown only in another tab is not seen"] = function()
  fake("fake", { "sh", "-c", "read _; echo crash-output; exit 1" })
  local info = child.lua([[
    vim.cmd("tabnew")
    _G.s = assert(T.open())
    vim.cmd("stopinsert")
    vim.cmd("tabprevious")
    vim.fn.chansend(s.job, "\n")
    wait(function() return s.exit_code ~= nil end)
    local first = assert(T.open())
    return { first_same = first == s, buf = vim.api.nvim_buf_is_valid(s.buf) }
  ]])
  eq({ info.first_same, info.buf }, { true, true })
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(
    vim.endswith(notes[1].msg, "Run :Duet open to see the output, then press i to restart the agent or q to close it."),
    true
  )
  -- Seen now, so opening again restarts.
  eq(child.lua_get("T.open() ~= s"), true)
end

T["exit"]["entering the terminal in another tab counts as seeing it"] = function()
  fake("fake", { "sh", "-c", "read _; echo out; exit 1" })
  child.lua([[
    vim.cmd("tabnew")
    _G.s = assert(T.open())
    vim.cmd("stopinsert")
    vim.cmd("tabprevious")
    vim.fn.chansend(s.job, "\n")
    wait(function() return s.exit_code ~= nil end)
    vim.cmd("tabnext")
    vim.api.nvim_set_current_win(s:window())
  ]])
  eq(child.lua_get("T.open() ~= s and T.current():is_running()"), true)
end

T["exit"]["the hint names only the keys duet mapped"] = MiniTest.new_set({
  parametrize = {
    { "defaults", {}, "In the terminal, press i to restart the agent or q to close it." },
    { "q = hide", { q = "hide" }, "In the terminal, press i to restart the agent." },
    { "i = hide", { i = "hide" }, "In the terminal, press a to restart the agent or q to close it." },
  },
})

T["exit"]["the hint names only the keys duet mapped"]["%s"] = function(_, keys, hint)
  fake("fake", { "sh", "-c", "sleep 0.2; exit 3" }, {}, { terminal = { keys = keys } })
  child.lua("local s = assert(T.open()); wait(function() return s.exit_code ~= nil end)")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(vim.split(notes[1].msg, "\n")[2], hint)
end

T["exit"]["closing the last window does not pile up empty buffers"] = function()
  fake("fake", CAT)
  local counts = child.lua([[
    local function listed() return #vim.fn.getbufinfo({ buflisted = 1 }) end
    local before = listed()
    for _ = 1, 3 do
      local s = assert(T.open())
      vim.cmd("only")
      assert(s:stop())
    end
    return { before = before, after = listed() }
  ]])
  eq(counts.after, counts.before)
end

T["exit"]["a clean exit in the command-line window closes the terminal once it is left"] = function()
  fake("fake", { "sh", "-c", "read _; exit 0" })
  child.lua([[
    _G.s = assert(T.open())
    vim.cmd("stopinsert")
    vim.cmd("wincmd p")
  ]])
  child.type_keys("q:")
  eq(child.fn.getcmdwintype(), ":")
  child.lua("vim.fn.chansend(s.job, '\\n'); wait(function() return s.exit_code ~= nil end); vim.wait(50)")
  eq(child.lua_get("vim.api.nvim_buf_is_valid(s.buf)"), true)
  child.type_keys("<C-c>")
  child.lua("wait(function() return not vim.api.nvim_buf_is_valid(s.buf) end)")
  eq(
    child.lua_get(
      "{ buf = vim.api.nvim_buf_is_valid(s.buf), listed = T.get(s.id) ~= nil, cmdwin = vim.fn.getcmdwintype() }"
    ),
    {
      buf = false,
      listed = false,
      cmdwin = "",
    }
  )
  eq(child.lua_get("_G.notes"), {})
end

T["exit"]["keys from terminal.keys keep their action"] = MiniTest.new_set({
  parametrize = {
    { "q = hide", { q = "hide" }, "q", "hide" },
    { "q = false", { q = false }, "q", "close" },
    { "i = hide", { i = "hide" }, "i", "hide" },
    { "a = hide, i restarts", { a = "hide" }, "i", "restart" },
    { "q = normal_mode, q still closes", { q = "normal_mode" }, "q", "close" },
  },
})

T["exit"]["keys from terminal.keys keep their action"]["%s"] = function(_, keys, key, expected)
  fake("fake", { "sh", "-c", "sleep 0.2; exit 3" }, {}, { terminal = { keys = keys } })
  child.lua([[
    _G.s = assert(T.open())
    wait(function() return s.exit_code ~= nil end)
  ]])
  child.type_keys(key)
  child.lua("vim.wait(100)")
  local info = child.lua_get([[{
    visible = s:is_visible(), listed = T.get(s.id) ~= nil,
    restarted = T.current() ~= nil and T.current() ~= s and T.current():is_running(),
  }]])
  local want = ({
    hide = { visible = false, listed = true, restarted = false },
    close = { visible = false, listed = false, restarted = false },
    restart = { visible = false, listed = false, restarted = true },
  })[expected]
  eq(info, want)
end

T["exit"]["stopping closes the panel even when wiping would keep the window"] = function()
  fake("fake", CAT)
  local info = child.lua([[
    -- See "a clean exit closes the panel even when wiping would keep the window".
    local delete = vim.api.nvim_buf_delete
    vim.api.nvim_buf_delete = function(buf, opts)
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
      return delete(buf, opts)
    end
    local s = assert(T.open())
    local win = s:window()
    assert(s:stop())
    vim.api.nvim_buf_delete = delete
    return { win_valid = vim.api.nvim_win_is_valid(win), wins = #vim.api.nvim_tabpage_list_wins(0) }
  ]])
  eq(info, { win_valid = false, wins = 1 })
end

T["exit"]["reports the reason"] = MiniTest.new_set({
  parametrize = {
    { "sh -c 'kill -INT $$'", { "sh", "-c", "sleep 0.2; kill -INT $$" }, "exited with code 130: interrupted (SIGINT)" },
    {
      "a missing command",
      { "sh", "-c", "sleep 0.2; exec duet-no-such-command" },
      "exited with code 127: command not found",
    },
  },
})

T["exit"]["reports the reason"]["%s"] = function(_, cmd, expected)
  fake("fake", cmd)
  child.lua("local s = assert(T.open()); wait(function() return s.exit_code ~= nil end)")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(notes[1].level, child.lua_get("vim.log.levels.ERROR"))
  eq(notes[1].msg:find(expected, 1, true) ~= nil, true)
end

T["exit"]["close_on_exit"] = MiniTest.new_set({
  parametrize = {
    { "never", 0, true, 0 },
    { "never", 3, true, 1 },
    { "always", 0, false, 0 },
    { "always", 3, false, 1 },
    { "success", 0, false, 0 },
    { "success", 3, true, 1 },
  },
})

T["exit"]["close_on_exit"]["%s, code %d"] = function(policy, code, kept, notes)
  fake("fake", { "sh", "-c", "sleep 0.2; exit " .. code }, {}, { terminal = { close_on_exit = policy } })
  local info = child.lua([[
    local s = assert(T.open())
    wait(function() return s.exit_code ~= nil end)
    vim.wait(50)
    return { buf = vim.api.nvim_buf_is_valid(s.buf), win = s:window() ~= nil }
  ]])
  eq(info, { buf = kept, win = kept })
  local got = child.lua_get("_G.notes")
  eq(#got, notes)
  -- The terminal is gone, so there is nothing to open.
  if notes > 0 and not kept then
    eq(got[1].msg:find("press i", 1, true), nil)
  end
end

T["exit"]["an error exit while hidden says how to see the output"] = function()
  fake("fake", { "sh", "-c", "sleep 0.2; echo boom; exit 3" })
  child.lua("local s = assert(T.open()); s:hide(); wait(function() return s.exit_code ~= nil end)")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(
    vim.endswith(
      notes[1].msg,
      "boom\nRun :Duet open to see the output, then press i to restart the agent or q to close it."
    ),
    true
  )
end

T["exit"]["exits caused by duet are quiet"] = MiniTest.new_set({
  parametrize = { { "stop" }, { "restart" }, { "stop_all" } },
})

T["exit"]["exits caused by duet are quiet"]["%s"] = function(action)
  fake("fake", CAT)
  child.lua(
    [[
    local s = assert(T.open())
    local job = s.job
    if ... == "stop" then s:stop() elseif ... == "restart" then assert(T.restart()) else T.stop_all() end
    wait(function() return not running(job) end)
    vim.wait(50)
  ]],
    { action }
  )
  eq(child.lua_get("_G.notes"), {})
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

T["session"]["reopening an agent that exited while hidden shows it, then restarts it"] = function()
  fake("fake", CAT)
  local old = child.lua([[
    local s = T.open()
    s:hide()
    vim.fn.jobstop(s.job)
    wait(function() return s.exit_code ~= nil end)
    return s.id
  ]])
  local function open()
    return child.lua([[
      local s = assert(T.open())
      return {
        id = s.id, running = s:is_running(), visible = s:is_visible(),
        current = vim.api.nvim_get_current_win() == s:window(),
      }
    ]])
  end
  -- First the exited terminal, so its output can be read.
  local first = open()
  eq(first, { id = old, running = false, visible = true, current = true })
  local second = open()
  eq(second.id ~= old, true)
  eq({ second.running, second.visible, second.current }, { true, true, true })
  -- jobstop() sends SIGHUP, which duet did not cause.
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(notes[1].msg:find("exited with code 129: hangup (SIGHUP)", 1, true) ~= nil, true)
end

T["session"][":Duet shows an agent that exited while hidden, then restarts it"] = function()
  fake("fake", CAT)
  local old = child.lua([[
    local s = T.open()
    s:hide()
    vim.fn.jobstop(s.job)
    wait(function() return s.exit_code ~= nil end)
    return s.id
  ]])
  child.cmd("Duet")
  eq(child.lua_get("{ T.current().id, T.current():is_visible(), T.current():is_running() }"), { old, true, false })
  child.cmd("Duet")
  eq(child.lua_get("T.current():is_visible()"), false)
  child.cmd("Duet")
  eq(child.lua_get("T.current().id ~= ...", { old }), true)
  eq(child.lua_get("T.current():is_visible() and T.current():is_running()"), true)
end

T["session"]["opening an agent that exited while shown restarts it"] = function()
  fake("fake", CAT, {}, { terminal = { close_on_exit = "never" } })
  local old = child.lua([[
    local s = T.open()
    vim.fn.jobstop(s.job)
    wait(function() return s.exit_code ~= nil end)
    vim.cmd.wincmd("p")
    return s.id
  ]])
  eq(child.lua_get("T.open().id ~= ...", { old }), true)
end

T["session"]["an invalid border fails cleanly"] = function()
  fake("fake", CAT, { "mcp.json" }, { terminal = { layout = "float", float = { border = "thick" } } })
  local before = child.lua("return { bufs = #vim.api.nvim_list_bufs(), wins = #vim.api.nvim_list_wins() }")
  local result = child.lua("return { T.open() }")
  eq(result[1], vim.NIL)
  eq(result[2]:match("^terminal: cannot open window: .*border") ~= nil, true)
  eq(child.lua_get("run_entries()"), {})
  eq(child.lua_get("#T.list()"), 0)
  eq(child.lua("return { bufs = #vim.api.nvim_list_bufs(), wins = #vim.api.nvim_list_wins() }"), before)
  child.cmd("Duet open")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.ERROR)
end

T["session"]["a failed restart keeps the running session on screen"] = function()
  fake("fake", CAT, { "mcp.json" })
  local old = child.lua("local s = T.open(); return { id = s.id, win = s:window(), job = s.job }")
  child.lua([[require("duet").setup({ agent = "fake", agents = { fake = { cmd = { "duet-no-such-binary" } } } })]])
  local result = child.lua("return { T.restart() }")
  eq(result[1], vim.NIL)
  eq(result[2]:match("^terminal: cannot start fake") ~= nil, true)
  eq(child.lua_get("T.get(...):window()", { old.id }), old.win)
  eq(child.lua_get("running(...)", { old.job }), true)
  eq(#child.lua_get("run_entries()"), 1)
  eq(child.lua_get("#T.list()"), 1)
end

T["session"]["a failed start keeps the other session on screen"] = function()
  fake("one", CAT)
  fake("two", { "duet-no-such-binary" })
  local one = child.lua_get("T.open('one').id")
  local result = child.lua("return { T.open('two') }")
  eq(result[1], vim.NIL)
  eq(child.lua_get("T.get(...):is_visible()", { one }), true)
end

T["session"]["a failed start in a lent window keeps that window"] = function()
  fake("fake", { "duet-no-such-binary" })
  local info = child.lua([[
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_win_set_buf(win, scratch)
    local s, err = T.Session.new(require("duet.agents").get("fake"), { win = win })
    return { s = s == nil, err = err ~= nil, valid = vim.api.nvim_win_is_valid(win) }
  ]])
  eq(info, { s = true, err = true, valid = true })
end

T["session"]["stop returns an error instead of throwing"] = function()
  fake("fake", CAT)
  -- Deleting a buffer can fail (e.g. E11 from the command-line window on Neovim 0.12; the
  -- exact cases vary by version), so make it fail on purpose.
  local stop = child.lua([[
    local s = T.open()
    _G.job = s.job
    local delete = vim.api.nvim_buf_delete
    vim.api.nvim_buf_delete = function() error("E11: Invalid in command-line window") end
    local result = { T.close({ stop = true }) }
    vim.api.nvim_buf_delete = delete
    vim.api.nvim_buf_delete(s.buf, { force = true })
    return result
  ]])
  eq(stop[1], vim.NIL)
  eq(stop[2]:match("^terminal: cannot close fake's buffer: .*E11") ~= nil, true)
  -- The agent is stopped anyway.
  eq(child.lua_get("#T.list()"), 0)
  eq(child.lua_get("wait(function() return not running(_G.job) end)"), true)
end

T["session"][":qa quits with an agent running"] = function()
  -- E947 would refuse :qa while a terminal job runs; check that it doesn't, and that
  -- VimLeavePre cleans up, on every Neovim version CI runs.
  local run = h.tmp_dir()
  local marker = vim.fs.joinpath(h.tmp_dir(), "not-quit")
  local script = vim.fs.joinpath(h.tmp_dir(), "script.lua")
  vim.fn.writefile({
    "vim.opt.rtp:prepend(vim.fn.getcwd())",
    "require('duet.agents').register({ name = 'fake', cmd = { 'sh', '-c', 'cat' },",
    "  capabilities = { mcp = false, plan_hook = false, system_prompt = false },",
    "  launch = function(self, spec)",
    "    return { argv = self.cmd, env = {}, files = { { path = spec.run_dir .. '/f', content = 'x' } } }",
    "  end })",
    "local s = assert(require('duet.terminal').open('fake'))",
    "assert(vim.uv.fs_stat(s.run_dir .. '/f'))",
    "s:hide()",
    "vim.cmd('qa')",
    "vim.fn.writefile({}, " .. vim.inspect(marker) .. ")",
  }, script)
  local saved = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = run
  local result = vim.system({ vim.v.progpath, "--headless", "--clean", "-l", script }, { text = true }):wait(10000)
  vim.env.XDG_RUNTIME_DIR = saved
  eq({ result.code, vim.uv.fs_stat(marker) == nil }, { 0, true })
  eq(vim.fn.glob(vim.fs.joinpath(run, "**", "duet", "*"), true, true), {})
end

T["session"]["glob characters in argv leave other buffers alone"] = function()
  fake("fake", { "sh", "-c", "cat # * ? [a] ~" })
  local user = child.lua([[
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, vim.fn.getcwd() .. "/notes.txt")
    return b
  ]])
  child.lua("assert(T.open())")
  eq(child.lua_get("vim.api.nvim_buf_is_valid(...)", { user }), true)
  local leftovers = child.lua([[
    return vim.tbl_filter(function(b)
      return vim.startswith(vim.api.nvim_buf_get_name(b), "term://")
    end, vim.api.nvim_list_bufs())
  ]])
  eq(leftovers, {})
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

T["session"]["deleting or unloading the buffer forgets the session quietly"] = MiniTest.new_set({
  parametrize = { { "bdelete!" }, { "bunload!" }, { "bwipeout!" } },
})

T["session"]["deleting or unloading the buffer forgets the session quietly"]["%s"] = function(cmd)
  fake("fake", CAT, { "mcp.json" })
  local s = child.lua("local s = T.open(); return { id = s.id, buf = s.buf, job = s.job }")
  child.cmd(cmd .. " " .. s.buf)
  eq(child.lua("local job = ...; return wait(function() return not running(job) end)", { s.job }), true)
  child.lua("vim.wait(100)")
  eq(child.lua_get("T.get(...) == nil", { s.id }), true)
  eq(child.lua_get("run_entries()"), {})
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

T["commands"][":Duet! close {agent} stops that agent"] = function()
  fake("one", CAT)
  fake("two", CAT)
  local one = child.lua_get("T.open('one').job")
  local two = child.lua_get("T.open('two').job")
  child.cmd("Duet! close one")
  eq(child.lua_get("T.find('one', T.root()) == nil"), true)
  eq(child.lua_get("running(...)", { two }), true)
  eq(child.lua("local job = ...; return wait(function() return not running(job) end)", { one }), true)
  child.cmd("Duet close nope")
  eq(child.lua_get("_G.notes[#_G.notes].msg"), "[duet] terminal: no nope session for this project")
  eq(child.fn.getcompletion("Duet close o", "cmdline"), { "one" })
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

T["layout"]["the default is an 80-column panel on the right"] = function()
  fake("fake", CAT)
  local info = child.lua([[
    local s = T.open()
    local win = s:window()
    local wo = vim.wo[win]
    local pos = vim.api.nvim_win_get_position(win)
    return {
      relative = vim.api.nvim_win_get_config(win).relative,
      width = vim.api.nvim_win_get_width(win),
      right_edge = pos[2] + vim.api.nvim_win_get_width(win) == vim.o.columns,
      full_height = vim.api.nvim_win_get_height(win) == vim.o.lines - vim.o.cmdheight - 1,
      top = pos[1],
      opts = {
        winfixwidth = wo.winfixwidth, wrap = wo.wrap, list = wo.list, number = wo.number,
        relativenumber = wo.relativenumber, signcolumn = wo.signcolumn, cursorline = wo.cursorline,
        colorcolumn = wo.colorcolumn, statuscolumn = wo.statuscolumn,
      },
    }
  ]])
  eq(info.relative, "")
  eq(info.width, 80)
  eq({ info.right_edge, info.full_height, info.top }, { true, true, 0 })
  eq(info.opts, {
    winfixwidth = true,
    wrap = false,
    list = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    cursorline = false,
    colorcolumn = "",
    statuscolumn = "",
  })
end

T["layout"]["the panel is full height with other splits open"] = function()
  fake("fake", CAT)
  child.cmd("split | vsplit")
  local info = child.lua([[
    local win = T.open():window()
    return {
      height = vim.api.nvim_win_get_height(win), lines = vim.o.lines - vim.o.cmdheight - 1,
      right_edge = vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win) == vim.o.columns,
    }
  ]])
  eq(info.height, info.lines)
  eq(info.right_edge, true)
end

T["layout"]["show() leaves the cursor, open() moves it"] = function()
  fake("fake", CAT)
  local info = child.lua([[
    local code = vim.api.nvim_get_current_win()
    local s = assert(T.open())
    s:hide()
    vim.api.nvim_set_current_win(code)
    local win = assert(s:show())
    local after_show = vim.api.nvim_get_current_win()
    s:hide()
    T.open()
    return { show_kept = after_show == code, open_moved = vim.api.nvim_get_current_win() == s:window() }
  ]])
  eq(info, { show_kept = true, open_moved = true })
end

T["layout"]["window options stay with the terminal buffer"] = function()
  fake("fake", CAT)
  child.lua("vim.o.wrap = true; vim.o.list = true; vim.o.cursorline = true; vim.o.colorcolumn = '80'")
  local info = child.lua([[
    local win = T.open():window()
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, other)
    local wo = vim.wo[win]
    return { wrap = wo.wrap, list = wo.list, cursorline = wo.cursorline, colorcolumn = wo.colorcolumn }
  ]])
  eq(info, { wrap = true, list = true, cursorline = true, colorcolumn = "80" })
end

T["layout"]["a float is still available"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "float" } })
  eq(child.lua_get("vim.api.nvim_win_get_config(T.open():window()).relative"), "editor")
end

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

T["layout"]["restart keeps the terminal's window options"] = MiniTest.new_set({
  parametrize = { { "right" }, { "float" } },
})

T["layout"]["restart keeps the terminal's window options"]["%s"] = function(layout)
  fake("fake", CAT, {}, { terminal = { layout = layout } })
  -- Neovim's own TermOpen autocmd turns off number and signcolumn for new terminals, but
  -- not spell, and users can remove that autocmd.
  child.lua("vim.o.number = true; vim.o.signcolumn = 'yes'; vim.o.spell = true")
  local info = child.lua([[
    local s = T.open()
    local win = s:window()
    local new = assert(T.restart())
    return {
      same = new:window() == win,
      number = vim.wo[win].number, signcolumn = vim.wo[win].signcolumn, spell = vim.wo[win].spell,
      fix = vim.wo[win].winfixwidth,
    }
  ]])
  eq(info.same, true)
  eq({ info.number, info.signcolumn, info.spell }, { false, "no", false })
  eq(info.fix, layout == "right")
end

T["layout"]["resizing the editor resizes fractional splits and keeps hand sizes"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "right", split = { width = 0.5 } } })
  local widths = child.lua([[
    local s = T.open()
    local win = s:window()
    vim.o.columns = 120
    vim.cmd("doautocmd VimResized")
    local fraction = vim.api.nvim_win_get_width(win)
    require("duet").setup({ agent = "fake", terminal = { layout = "right", split = { width = 30 } } })
    return fraction
  ]])
  -- A separate call, so WinResized sees the resize by hand before the editor resize.
  child.lua("vim.api.nvim_win_set_width(T.current():window(), 40)")
  local absolute = child.lua([[
    vim.o.columns = 100
    vim.cmd("doautocmd VimResized")
    return vim.api.nvim_win_get_width(T.current():window())
  ]])
  eq({ widths, absolute }, { 60, 40 })
end

T["layout"]["the default panel leaves room for code on an 80-column editor"] = function()
  fake("fake", CAT)
  child.o.columns = 80
  local widths = child.lua([[
    local code = vim.api.nvim_get_current_win()
    local s = T.open()
    return { panel = vim.api.nvim_win_get_width(s:window()), code = vim.api.nvim_win_get_width(code) }
  ]])
  eq(widths, { panel = 59, code = 20 })
end

T["layout"]["shrinking the editor shrinks an absolute split"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "right", split = { width = 80 } } })
  local widths = child.lua([[
    local code = vim.api.nvim_get_current_win()
    local s = T.open()
    local win = s:window()
    local function sizes()
      return { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_width(code) }
    end
    local out = { open = sizes() }
    vim.o.columns = 90
    vim.cmd("doautocmd VimResized")
    out.shrunk = sizes()
    vim.o.columns = 200
    vim.cmd("doautocmd VimResized")
    out.grown = sizes()
    return out
  ]])
  eq(widths, { open = { 80, 119 }, shrunk = { 69, 20 }, grown = { 80, 119 } })
end

T["layout"]["a split resized by hand keeps its size until it no longer fits"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "right", split = { width = 80 } } })
  child.lua("_G.win = T.open():window()")
  -- A separate call, so WinResized sees the resize by hand before the editor resizes.
  child.lua("vim.api.nvim_win_set_width(win, 40)")
  local widths = {}
  for _, columns in ipairs({ 100, 200, 50, 200 }) do
    child.o.columns = columns
    widths[#widths + 1] = child.lua_get("vim.api.nvim_win_get_width(win)")
  end
  eq(widths, { 40, 40, 29, 40 })
end

T["layout"]["a split Neovim shrinks by itself grows back"] = MiniTest.new_set({
  parametrize = {
    { "min_code_width = 0", { split = { width = 80, min_code_width = 0 } }, "", 50 },
    { "winminwidth above min_code_width", {}, "vim.o.winwidth = 30; vim.o.winminwidth = 30", 90 },
  },
})

T["layout"]["a split Neovim shrinks by itself grows back"]["%s"] = function(_, terminal, setup, small)
  fake("fake", CAT, {}, { terminal = terminal })
  child.lua(setup)
  child.lua("_G.code = vim.api.nvim_get_current_win(); _G.win = T.open():window()")
  child.o.columns = small
  local shrunk = child.lua_get("{ vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_width(code) }")
  child.o.columns = 200
  eq(shrunk[1] < 80, true)
  eq(shrunk[1] + shrunk[2] + 1, small)
  eq(child.lua_get("vim.api.nvim_win_get_width(win)"), 80)
end

T["layout"]["restarting in a window of the user's does not make it a split"] = function()
  fake("fake", CAT)
  child.lua([[
    _G.left = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    _G.right = vim.api.nvim_get_current_win()
    local s = T.open()
    local buf = s.buf
    s:hide()
    vim.api.nvim_win_set_buf(left, buf)
    assert(T.restart())
  ]])
  local info = child.lua_get([[{
    layout = vim.w[left].duet_layout or false,
    fix = vim.wo[left].winfixwidth,
    terminal = vim.api.nvim_win_get_buf(left) == T.current().buf,
  }]])
  eq(info, { layout = false, fix = false, terminal = true })
  -- duet does not size the window as a panel, so the other one is not squeezed.
  child.o.columns = 150
  eq(child.lua_get("vim.api.nvim_win_get_width(left) ~= 80"), true)
  child.o.columns = 60
  eq(child.lua_get("vim.api.nvim_win_get_width(right) > 1"), true)
end

T["layout"]["a window the terminal left is not a split any more"] = function()
  fake("fake", CAT)
  -- open() focuses the panel, so :only leaves it as the tab's last window, and hiding the
  -- session puts another buffer in it instead of closing it.
  child.lua([[
    local s = T.open()
    _G.win, _G.buf = s:window(), s.buf
    vim.cmd("only")
    assert(s:hide())
  ]])
  eq(
    child.lua_get([[{
      valid = vim.api.nvim_win_is_valid(win),
      layout = vim.w[win].duet_layout or false,
      fix = vim.wo[win].winfixwidth,
    }]]),
    { valid = true, layout = false, fix = false }
  )
  child.lua("vim.cmd('vsplit')")
  eq(child.lua_get("vim.w[win].duet_hand or false"), false)
  -- Shown there again and restarted, it is not sized as a panel.
  child.lua("vim.api.nvim_win_set_buf(win, buf); assert(T.restart())")
  eq(child.lua_get("{ vim.w[win].duet_layout or false, vim.wo[win].winfixwidth }"), { false, false })
  child.o.columns = 150
  eq(child.lua_get("vim.api.nvim_win_get_width(win) ~= 80"), true)
end

T["layout"]["a window enlarged on enter is not a hand size"] = MiniTest.new_set({
  parametrize = {
    { "defaults on a narrow editor", {}, 30 },
    { "min_code_width below winwidth", { split = { min_code_width = 10 } }, 100 },
  },
})

T["layout"]["a window enlarged on enter is not a hand size"]["%s"] = function(_, terminal, columns)
  fake("fake", CAT, {}, { terminal = terminal })
  child.o.columns = columns
  -- open() focuses the panel; moving back makes Neovim widen the code to 'winwidth'.
  child.lua("_G.code = vim.api.nvim_get_current_win(); _G.win = T.open():window()")
  child.lua("vim.api.nvim_set_current_win(code)")
  eq(child.lua_get("{ vim.api.nvim_win_get_width(code), vim.w[win].duet_hand or false }"), { 20, false })
  child.o.columns = 200
  eq(child.lua_get("vim.api.nvim_win_get_width(win)"), 80)
end

T["layout"]["a resize by hand after an enlargement is still noticed"] = function()
  fake("fake", CAT)
  child.o.columns = 30
  child.lua("_G.code = vim.api.nvim_get_current_win(); _G.win = T.open():window()")
  -- Neovim widens the code to 'winwidth' and takes the columns from the panel.
  child.lua("vim.api.nvim_set_current_win(code)")
  eq(child.lua_get("{ vim.api.nvim_win_get_width(win), vim.w[win].duet_hand or false }"), { 9, false })
  child.lua("vim.api.nvim_win_set_width(win, 5)")
  eq(child.lua_get("vim.w[win].duet_hand or false"), 5)
end

T["layout"]["restarting in a sidebar of the user's keeps its fixed width"] = function()
  fake("fake", CAT)
  child.lua([[
    vim.cmd("vsplit")
    _G.side = vim.api.nvim_get_current_win()
    vim.wo[side].winfixwidth = true
    local s = T.open()
    local buf = s.buf
    s:hide()
    vim.api.nvim_win_set_buf(side, buf)
    assert(T.restart())
  ]])
  eq(child.lua_get("{ vim.wo[side].winfixwidth, vim.w[side].duet_layout or false }"), { true, false })
end

T["layout"]["a panel showing another buffer is not tracked"] = function()
  fake("fake", CAT)
  child.lua("_G.win = T.open():window(); vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))")
  -- A separate call, so WinResized sees the resize.
  child.lua("vim.api.nvim_win_set_width(win, 50)")
  eq(child.lua_get("vim.w[win].duet_hand or false"), false)
end

T["layout"]["a split in another tab follows editor resizes"] = function()
  fake("fake", CAT)
  child.lua("_G.win = T.open():window(); vim.cmd('tabnew')")
  child.o.columns = 90
  child.lua("vim.cmd('tabprevious')")
  local shrunk = child.lua_get("{ vim.api.nvim_win_get_width(win), vim.w[win].duet_hand or false }")
  child.lua("vim.cmd('tabnext')")
  child.o.columns = 200
  child.lua("vim.cmd('tabprevious')")
  local grown = child.lua_get("{ vim.api.nvim_win_get_width(win), vim.w[win].duet_hand or false }")
  eq({ shrunk, grown }, { { 69, false }, { 80, false } })
end

T["layout"]["a hand size gives way to a size set with setup()"] = MiniTest.new_set({
  parametrize = { { "from a fraction", 0.5 }, { "from an absolute size", 80 } },
})

T["layout"]["a hand size gives way to a size set with setup()"]["%s"] = function(_, width)
  fake("fake", CAT, {}, { terminal = { split = { width = width } } })
  child.lua("_G.win = T.open():window()")
  -- A separate call, so WinResized sees the resize by hand before the editor resizes.
  child.lua("vim.api.nvim_win_set_width(win, 30)")
  child.lua([[require("duet").setup({ agent = "fake", terminal = { split = { width = 100 } } })]])
  child.o.columns = 199
  eq(child.lua_get("vim.api.nvim_win_get_width(win)"), 100)
end

T["layout"]["a tiny editor shares its width with the panel"] = function()
  fake("fake", CAT)
  child.o.columns = 20
  local widths = child.lua([[
    local code = vim.api.nvim_get_current_win()
    local s = T.open()
    return { panel = vim.api.nvim_win_get_width(s:window()), code = vim.api.nvim_win_get_width(code) }
  ]])
  eq(widths, { panel = 9, code = 10 })
end

T["layout"]["shrinking the editor shrinks an absolute bottom split"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "bottom", split = { height = 30 } } })
  local info = child.lua([[
    local code = vim.api.nvim_get_current_win()
    local s = T.open()
    local win = s:window()
    vim.o.lines = 20
    vim.cmd("doautocmd VimResized")
    return { panel = vim.api.nvim_win_get_height(win), code = vim.api.nvim_win_get_height(code) }
  ]])
  eq(info.code >= 5, true)
  eq(info.panel, child.lua_get("vim.o.lines - vim.o.cmdheight - 1") - 5 - 1)
end

T["layout"]["resizing keeps a float's own border"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "float", float = { width = 1, height = 1, border = "none" } } })
  local cfg = child.lua([[
    local s = T.open()
    require("duet").setup({
      agent = "fake",
      terminal = { layout = "float", float = { width = 1, height = 1, border = "rounded" } },
    })
    vim.cmd("doautocmd VimResized")
    local c = vim.api.nvim_win_get_config(s:window())
    return { width = c.width, col = c.col }
  ]])
  eq(cfg, { width = child.o.columns, col = 0 })
end

T["layout"]["a float stays below the tabline"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "float", float = { width = 1, height = 1, border = "none" } } })
  child.o.showtabline = 2
  local row = child.lua("local s = T.open(); return vim.api.nvim_win_get_position(s:window())[1]")
  eq(row, 1)
end

T["layout"]["a float moves below a tabline that appears"] = function()
  fake("fake", CAT, {}, { terminal = { layout = "float", float = { width = 1, height = 1, border = "none" } } })
  child.lua("_G.win = T.open():window()")
  local before = child.lua_get("vim.api.nvim_win_get_position(win)[1]")
  child.lua("vim.cmd('tabnew')")
  child.lua("vim.cmd('tabprevious')")
  eq({ before, child.lua_get("vim.api.nvim_win_get_position(win)[1]") }, { 0, 1 })
end

T["layout"]["switching sessions gives the new split its full size"] = function()
  fake("one", CAT)
  fake("two", CAT)
  child.o.columns = 120
  -- The new split opens beside the old one, so it gets only what 'winminwidth' leaves.
  child.lua("vim.o.winwidth = 30; vim.o.winminwidth = 30")
  child.lua("_G.code = vim.api.nvim_get_current_win(); assert(T.open('one'))")
  child.lua("_G.win = assert(T.open('two')):window()")
  local function sizes()
    return child.lua_get([[{
      panel = vim.api.nvim_win_get_width(win),
      code = vim.api.nvim_win_get_width(code),
      hand = vim.w[win].duet_hand or false,
    }]])
  end
  eq(sizes(), { panel = 80, code = 39, hand = false })
  child.lua("vim.cmd('doautocmd VimResized')")
  eq(sizes(), { panel = 80, code = 39, hand = false })
end

-- Changes that take lines from the windows without resizing the editor: { name, change, undo }.
-- Each runs in its own call, so WinResized sees what it did. `laststatus` starts at 0.
local LINES_TAKEN = {
  { "a tab page", { "vim.cmd('tabnew')", "vim.cmd('tabprevious')" }, { "vim.cmd('tabnext')", "vim.cmd('tabclose')" } },
  { "showtabline", { "vim.o.showtabline = 2" }, { "vim.o.showtabline = 1" } },
  { "cmdheight", { "vim.o.cmdheight = 2" }, { "vim.o.cmdheight = 1" } },
  { "laststatus", { "vim.o.laststatus = 2" }, { "vim.o.laststatus = 0" } },
}

-- A bottom split on a 41-line editor, with the tabline shown only for 2+ tabs and no status
-- line for the last window.
local function open_bottom(split)
  fake("fake", CAT, {}, { terminal = { layout = "bottom", split = split } })
  child.o.lines = 41
  child.lua("vim.o.showtabline = 1; vim.o.laststatus = 0")
  child.lua("_G.code = vim.api.nvim_get_current_win(); _G.win = T.open():window()")
end

local function run_all(calls)
  for _, call in ipairs(calls) do
    child.lua(call)
  end
end

T["layout"]["the code keeps min_code_height when lines are taken"] = MiniTest.new_set({ parametrize = LINES_TAKEN })

T["layout"]["the code keeps min_code_height when lines are taken"]["%s"] = function(_, change, undo)
  -- An absolute height too large for the editor is capped: the code gets exactly 5 lines.
  open_bottom({ height = 100 })
  local function sizes()
    return child.lua_get("{ vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_height(code) }")
  end
  local opened = sizes()
  run_all(change)
  local taken = sizes()
  run_all(undo)
  eq({ opened[2], taken[2], sizes() }, { 5, 5, opened })
  eq(taken[1] < opened[1], true)
  eq(child.lua_get("vim.w[win].duet_hand or false"), false)
end

T["layout"]["a hand size survives lines being taken"] = MiniTest.new_set({ parametrize = LINES_TAKEN })

T["layout"]["a hand size survives lines being taken"]["%s"] = function(_, change, undo)
  -- With no minimum, the split can take every line but the code's 'winminheight'.
  open_bottom({ height = 10, min_code_height = 0 })
  child.lua("vim.api.nvim_win_set_height(win, 100)")
  local hand = child.lua_get("vim.w[win].duet_hand")
  eq(hand, child.lua_get("vim.api.nvim_win_get_height(win)"))
  run_all(change)
  eq(child.lua_get("vim.w[win].duet_hand"), hand)
  run_all(undo)
  eq(child.lua_get("{ vim.api.nvim_win_get_height(win), vim.w[win].duet_hand }"), { hand, hand })
end

T["layout"]["entering a tab with its own cmdheight keeps room for code"] = function()
  open_bottom({ height = 100 })
  child.lua("vim.o.cmdheight = 3")
  child.lua("vim.cmd('tabnew')")
  -- 'cmdheight' is local to a tab page: this one does not change the first tab's.
  child.lua("vim.o.cmdheight = 1")
  child.lua("vim.cmd('tabprevious')")
  eq(child.lua_get("{ vim.o.cmdheight, vim.api.nvim_win_get_height(code) }"), { 3, 5 })
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
  split = { width = 0.4, height = 10, min_code_width = 20, min_code_height = 5 },
}

local ABSOLUTE = { float = OPTS.float, split = { width = 80, height = 30, min_code_width = 20, min_code_height = 5 } }

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
    name = "float with a shadow pads right and bottom only, no title",
    layout = "float",
    opts = { float = { width = 1, height = 1, border = "shadow" }, split = OPTS.split },
    expected = { relative = "editor", style = "minimal", border = "shadow", width = 99, height = 39, row = 0, col = 0 },
  },
  {
    name = "float with a list border without top and bottom edges",
    layout = "float",
    opts = { float = { width = 1, height = 1, border = { "", "", "", "|", "", "", "", "|" } }, split = OPTS.split },
    expected = {
      relative = "editor",
      style = "minimal",
      border = { "", "", "", "|", "", "", "", "|" },
      width = 98,
      height = 40,
      row = 0,
      col = 0,
    },
  },
  {
    name = "float below the tabline",
    layout = "float",
    opts = { float = { width = 1, height = 1, border = "none" }, split = OPTS.split },
    editor = { top = 1 },
    expected = { relative = "editor", style = "minimal", border = "none", width = 100, height = 40, row = 1, col = 0 },
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
  {
    name = "right split, absolute, capped on a small editor",
    layout = "right",
    opts = ABSOLUTE,
    editor = { columns = 80 },
    expected = { split = "right", win = -1, width = 59 },
  },
  {
    name = "left split, absolute, unchanged on a large editor",
    layout = "left",
    opts = ABSOLUTE,
    editor = { columns = 200 },
    expected = { split = "left", win = -1, width = 80 },
  },
  {
    name = "bottom split, absolute, capped on a small editor",
    layout = "bottom",
    opts = ABSOLUTE,
    editor = { lines = 20 },
    expected = { split = "below", win = -1, height = 14 },
  },
  {
    name = "bottom split, absolute, unchanged on a large editor",
    layout = "bottom",
    opts = ABSOLUTE,
    editor = { lines = 60 },
    expected = { split = "below", win = -1, height = 30 },
  },
  {
    name = "right split without min_code_width leaves the separator",
    layout = "right",
    opts = { float = OPTS.float, split = { width = 200, height = 0.4 } },
    editor = { columns = 120 },
    expected = { split = "right", win = -1, width = 119 },
  },
  {
    name = "right split, fraction, not capped on a small editor",
    layout = "right",
    opts = { float = OPTS.float, split = { width = 0.9, height = 0.4, min_code_width = 20, min_code_height = 5 } },
    editor = { columns = 30 },
    expected = { split = "right", win = -1, width = 27 },
  },
}

T["win_config()"] = MiniTest.new_set()
for _, case in ipairs(geometry_cases) do
  T["win_config()"][case.name] = function()
    h.reset_modules()
    local editor = vim.tbl_extend("force", { columns = 100, lines = 40 }, case.editor or {})
    eq(require("duet.terminal").win_config(case.layout, case.opts, editor, " t "), case.expected)
  end
end

local size_cases = {
  { name = "fraction", value = 0.5, total = 81, expected = 40 },
  { name = "one is the whole", value = 1, total = 80, expected = 80 },
  { name = "absolute", value = 30, total = 80, expected = 30 },
  { name = "absolute clamped", value = 300, total = 80, expected = 80 },
  { name = "tiny fraction is at least 1", value = 0.001, total = 80, expected = 1 },
}

local border_cases = {
  { name = "none", border = "none", expected = { 0, 0, 0, 0 } },
  { name = "nil", border = nil, expected = { 0, 0, 0, 0 } },
  { name = "named", border = "rounded", expected = { 1, 1, 1, 1 } },
  { name = "shadow", border = "shadow", expected = { 0, 1, 1, 0 } },
  { name = "one part repeats", border = { "x" }, expected = { 1, 1, 1, 1 } },
  { name = "two parts: edges are the second", border = { "+", "" }, expected = { 0, 0, 0, 0 } },
  { name = "four parts", border = { "", "-", "", "|" }, expected = { 1, 1, 1, 1 } },
  { name = "eight parts, left edge only", border = { "", "", "", "", "", "", "", "|" }, expected = { 0, 0, 0, 1 } },
  { name = "part with a highlight", border = { { "", "X" }, { "-", "X" } }, expected = { 1, 1, 1, 1 } },
}

T["border_size()"] = MiniTest.new_set()
for _, case in ipairs(border_cases) do
  T["border_size()"][case.name] = function()
    h.reset_modules()
    eq({ require("duet.terminal").border_size(case.border) }, case.expected)
  end
end

local reason_cases = {
  { name = "generic error", code = 3, expected = "see the terminal output" },
  { name = "not executable", code = 126, expected = "command not executable" },
  { name = "command not found", code = 127, expected = "command not found" },
  { name = "exit 128", code = 128, expected = "see the terminal output" },
  { name = "SIGHUP", code = 129, expected = "hangup (SIGHUP)" },
  { name = "SIGINT", code = 130, expected = "interrupted (SIGINT)" },
  { name = "SIGKILL", code = 137, expected = "killed (SIGKILL)" },
  { name = "SIGTERM", code = 143, expected = "terminated (SIGTERM)" },
  { name = "unnamed signal", code = 138, expected = "signal 10" },
  { name = "highest signal", code = 192, expected = "signal 64" },
  { name = "above signals", code = 193, expected = "see the terminal output" },
  { name = "exit 255", code = 255, expected = "see the terminal output" },
}

T["exit_reason()"] = MiniTest.new_set()
for _, case in ipairs(reason_cases) do
  T["exit_reason()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").exit_reason(case.code), case.expected)
  end
end

local long = string.rep("x", 250)

local tail_cases = {
  { name = "empty", lines = {}, n = 5, expected = {} },
  { name = "drops blank lines and trims", lines = { "a  ", "", "   ", "b\t", "", "" }, n = 5, expected = { "a", "b" } },
  {
    name = "keeps the last n",
    lines = { "1", "2", "3", "4", "5", "6", "7" },
    n = 5,
    expected = { "3", "4", "5", "6", "7" },
  },
  { name = "drops the exit line", lines = { "boom", "", "[Process exited 3]", "" }, n = 5, expected = { "boom" } },
  { name = "cuts long lines", lines = { long }, n = 5, expected = { string.rep("x", 199) .. "…" } },
}

T["tail()"] = MiniTest.new_set()
for _, case in ipairs(tail_cases) do
  T["tail()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").tail(case.lines, case.n), case.expected)
  end
end

local message_cases = {
  {
    name = "no output",
    args = { "claude", 3, {} },
    expected = "claude exited with code 3: see the terminal output",
  },
  {
    name = "with output",
    args = { "claude", 137, { "a", "b" } },
    expected = "claude exited with code 137: killed (SIGKILL)\na\nb",
  },
  {
    name = "with a hint",
    args = { "claude", 1, { "boom" }, "Press i." },
    expected = "claude exited with code 1: see the terminal output\nboom\nPress i.",
  },
}

local hint_cases = {
  {
    name = "both keys, shown",
    keys = { restart = "i", close = "q" },
    hidden = false,
    expected = "In the terminal, press i to restart the agent or q to close it.",
  },
  {
    name = "both keys, hidden",
    keys = { restart = "i", close = "q" },
    hidden = true,
    expected = "Run :Duet open to see the output, then press i to restart the agent or q to close it.",
  },
  {
    name = "restart only",
    keys = { restart = "a" },
    hidden = false,
    expected = "In the terminal, press a to restart the agent.",
  },
  { name = "close only", keys = { close = "q" }, hidden = false, expected = "In the terminal, press q to close it." },
  { name = "no keys, shown", keys = {}, hidden = false, expected = nil },
  { name = "no keys, hidden", keys = {}, hidden = true, expected = "Run :Duet open to see the output." },
}

T["exit_hint()"] = MiniTest.new_set()
for _, case in ipairs(hint_cases) do
  T["exit_hint()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").exit_hint(case.keys, case.hidden), case.expected)
  end
end

T["exit_message()"] = MiniTest.new_set()
for _, case in ipairs(message_cases) do
  T["exit_message()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").exit_message(unpack(case.args)), case.expected)
  end
end

-- args: total, keep
local split_cap_cases = {
  { name = "leaves keep plus the separator", args = { 80, 20 }, expected = 59 },
  { name = "large editor", args = { 200, 20 }, expected = 179 },
  { name = "keep 0 leaves the separator", args = { 80, 0 }, expected = 79 },
  { name = "at the crossover", args = { 41, 20 }, expected = 20 },
  { name = "too small for both shares evenly", args = { 20, 20 }, expected = 9 },
  { name = "lines too small for both share evenly", args = { 8, 5 }, expected = 3 },
  { name = "a single cell", args = { 1, 20 }, expected = 1 },
  { name = "keep defaults to 0", args = { 80 }, expected = 79 },
}

T["split_cap()"] = MiniTest.new_set()
for _, case in ipairs(split_cap_cases) do
  T["split_cap()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").split_cap(unpack(case.args)), case.expected)
  end
end

-- args: value, total, keep, hand
local split_target_cases = {
  { name = "fraction gets its share", args = { 0.5, 120, 20 }, expected = 60 },
  { name = "fraction ignores a hand size", args = { 0.5, 120, 20, 40 }, expected = 60 },
  { name = "fraction is not capped", args = { 0.9, 30, 20 }, expected = 27 },
  { name = "absolute fits", args = { 80, 200, 20 }, expected = 80 },
  { name = "absolute capped", args = { 80, 80, 20 }, expected = 59 },
  { name = "absolute exactly at the cap", args = { 59, 80, 20 }, expected = 59 },
  { name = "absolute on a tiny editor shares evenly", args = { 80, 20, 20 }, expected = 9 },
  { name = "hand size below the cap", args = { 80, 200, 20, 40 }, expected = 40 },
  { name = "hand size capped", args = { 80, 50, 20, 40 }, expected = 29 },
  { name = "hand size wider than configured", args = { 80, 200, 20, 120 }, expected = 120 },
  { name = "hand size of 1 is not a fraction", args = { 80, 200, 20, 1 }, expected = 1 },
}

T["split_target()"] = MiniTest.new_set()
for _, case in ipairs(split_target_cases) do
  T["split_target()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").split_target(unpack(case.args, 1, 4)), case.expected)
  end
end

T["resolve_size()"] = MiniTest.new_set()
for _, case in ipairs(size_cases) do
  T["resolve_size()"][case.name] = function()
    h.reset_modules()
    eq(require("duet.terminal").resolve_size(case.value, case.total), case.expected)
  end
end

return T
