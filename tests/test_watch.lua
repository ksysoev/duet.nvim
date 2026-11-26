local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local child = h.new_child()
local dir

-- _state() when nothing is watched.
local IDLE = { active = false, dirs = {}, failed = {}, pending = {}, timer = false }

-- Start a child with a fake agent and a temporary project with two files in two dirs.
local function start(opts)
  child.setup()
  dir = h.tmp_dir()
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.writefile({ "one" }, dir .. "/a.txt")
  vim.fn.writefile({ "two" }, dir .. "/sub/b.txt")
  child.lua(
    [[
    local opts, root = ...
    _G.notes = {}
    vim.notify = function(msg, level)
      table.insert(_G.notes, { msg = msg, level = level })
    end
    for _, name in ipairs({ "fake", "other" }) do
      require("duet.agents").register({
        name = name,
        cmd = { "sh", "-c", "cat" },
        capabilities = { mcp = false, plan_hook = false, system_prompt = false },
        launch = function(self)
          return { argv = vim.deepcopy(self.cmd), env = {}, files = {} }
        end,
      })
    end
    require("duet").setup(vim.tbl_deep_extend("force", { agent = "fake" }, opts))
    _G.W = require("duet.watch")
    _G.T = require("duet.terminal")
    _G.root = root
    _G.wait = function(fn, ms)
      return vim.wait(ms or 2000, fn, 10)
    end
    -- Start a hidden session of `name` (default "fake") or one with another command.
    _G.session = function(name, cmd)
      local agent = assert(require("duet.agents").get(name or "fake"))
      if cmd then
        agent.cmd = cmd
      end
      return assert(T.Session.new(agent, { root = root, hidden = true }))
    end
    _G.write = function(path, text)
      local f = assert(io.open(path, "w"))
      f:write(text)
      f:close()
    end
    _G.lines = function(buf)
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  ]],
    { opts or {}, dir }
  )
end

local T = MiniTest.new_set({
  hooks = {
    post_once = child.stop,
  },
})

-- Pure helpers ------------------------------------------------------------------

T["dir_of"] = MiniTest.new_set()

local dir_cases = {
  { name = "file", args = { "/p/a/b.lua", "", true }, want = "/p/a" },
  { name = "file with spaces", args = { "/p/my dir/b.lua", "", true }, want = "/p/my dir" },
  { name = "file at the root", args = { "/b.lua", "", true }, want = "/" },
  { name = "unnamed", args = { "", "", true }, want = nil },
  { name = "unlisted", args = { "/p/a/b.lua", "", false }, want = nil },
  { name = "terminal", args = { "term://~//1:sh", "terminal", true }, want = nil },
  { name = "nofile", args = { "/p/a/b.lua", "nofile", true }, want = nil },
  { name = "help", args = { "/p/doc/x.txt", "help", true }, want = nil },
  { name = "duet buffer", args = { "duet://claude/1", "", true }, want = nil },
  { name = "oil", args = { "oil:///p/a/", "", true }, want = nil },
  { name = "fugitive", args = { "fugitive:///p/.git//0/a.lua", "", true }, want = nil },
}

for _, case in ipairs(dir_cases) do
  T["dir_of"][case.name] = function()
    eq(require("duet.watch").dir_of(unpack(case.args)), case.want)
  end
end

T["dir_of"]["relative name is made absolute"] = function()
  eq(require("duet.watch").dir_of("x/b.lua", "", true), vim.fs.normalize(vim.fn.getcwd() .. "/x"))
end

T["busy"] = MiniTest.new_set()

local busy_cases = {
  { name = "normal", mode = { mode = "n", blocking = false }, cmdwin = false, want = false },
  { name = "terminal", mode = { mode = "t", blocking = false }, cmdwin = false, want = false },
  { name = "command line", mode = { mode = "c", blocking = false }, cmdwin = false, want = true },
  { name = "command-line window", mode = { mode = "n", blocking = false }, cmdwin = true, want = true },
  { name = "hit-enter prompt", mode = { mode = "r", blocking = false }, cmdwin = false, want = true },
  { name = "more prompt", mode = { mode = "rm", blocking = false }, cmdwin = false, want = true },
  { name = "shell command", mode = { mode = "!", blocking = false }, cmdwin = false, want = true },
  { name = "waiting for a key", mode = { mode = "n", blocking = true }, cmdwin = false, want = true },
}

for _, case in ipairs(busy_cases) do
  T["busy"][case.name] = function()
    eq(require("duet.watch").busy(case.mode, case.cmdwin), case.want)
  end
end

T["typing"] = MiniTest.new_set()

local typing_cases = {
  { mode = "n", want = false },
  { mode = "nt", want = false },
  { mode = "v", want = false },
  { mode = "niI", want = false },
  { mode = "t", want = true },
  { mode = "i", want = true },
  { mode = "ic", want = true },
  { mode = "R", want = true },
  { mode = "no", want = true },
  { mode = "nov", want = true },
}

for _, case in ipairs(typing_cases) do
  T["typing"][case.mode] = function()
    eq(require("duet.watch").typing(case.mode), case.want)
  end
end

-- Lifecycle -----------------------------------------------------------------------

T["lifecycle"] = MiniTest.new_set({ hooks = { pre_case = start } })

T["lifecycle"]["nothing is watched without a session"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt')")
  eq(child.lua_get("W._state()"), IDLE)
end

T["lifecycle"]["a session watches the dirs of listed file buffers"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); vim.cmd.badd(root .. '/sub/b.txt'); session()")
  local st = child.lua_get("W._state()")
  eq(st.active, true)
  eq(st.timer, true)
  eq(st.dirs, { dir, dir .. "/sub" })
  eq(child.lua_get("#vim.api.nvim_get_autocmds({ group = 'duet.watch' }) > 0"), true)
end

T["lifecycle"]["follows buffers added and deleted"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); session()")
  eq(child.lua_get("W._state().dirs"), { dir })
  child.lua("vim.cmd.edit(root .. '/sub/b.txt')")
  eq(child.lua_get("wait(function() return #W._state().dirs == 2 end)"), true)
  child.lua("vim.cmd.bdelete()")
  eq(child.lua_get("wait(function() return #W._state().dirs == 1 end)"), true)
  eq(child.lua_get("W._state().dirs"), { dir })
end

T["lifecycle"]["follows a buffer renamed with :file"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); session()")
  child.lua("vim.cmd.file(vim.fn.fnameescape(root .. '/sub/a.txt'))")
  eq(child.lua_get("wait(function() return W._state().dirs[1] == root .. '/sub' end)"), true)
  eq(child.lua_get("W._state().dirs"), { dir .. "/sub" })
end

T["lifecycle"]["skips a directory that does not exist"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); vim.cmd.badd(root .. '/missing/c.txt'); session()")
  eq(child.lua_get("W._state().dirs"), { dir })
end

T["lifecycle"]["no watchers remain after all sessions stop"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); _G.s1 = session('fake'); _G.s2 = session('other')")
  child.lua("s1:stop()")
  eq(child.lua_get("W._state().active"), true)
  eq(child.lua_get("W._state().dirs"), { dir })
  child.lua("s2:stop()")
  eq(child.lua_get("W._state()"), IDLE)
  -- The augroup is deleted.
  eq(child.lua_get("pcall(vim.api.nvim_get_autocmds, { group = 'duet.watch' })"), false)
end

T["lifecycle"]["stops when the agent exits by itself"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); session(nil, { 'sh', '-c', 'sleep 0.2' })")
  eq(child.lua_get("W._state().active"), true)
  eq(child.lua_get("wait(function() return not W._state().active end)"), true)
  eq(child.lua_get("W._state()"), IDLE)
end

T["lifecycle"]["keeps watching across a restart"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); _G.s1 = session(); _G.s2 = assert(s1:restart())")
  eq(child.lua_get("W._state().active"), true)
  child.lua("s2:stop()")
  eq(child.lua_get("W._state().active"), false)
end

T["lifecycle"]["stops on VimLeavePre"] = function()
  child.lua("vim.cmd.edit(root .. '/a.txt'); session()")
  child.lua("T.stop_all()")
  eq(child.lua_get("W._state()"), IDLE)
end

T["lifecycle"]["follows a buffer that becomes listed"] = function()
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.b = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(b, root .. '/sub/b.txt')
    session()
  ]])
  eq(child.lua_get("W._state().dirs"), { dir })
  child.lua("vim.bo[b].buflisted = true")
  eq(child.lua_get("wait(function() return #W._state().dirs == 2 end)"), true)
  child.lua("vim.bo[b].buftype = 'nofile'")
  eq(child.lua_get("wait(function() return #W._state().dirs == 1 end)"), true)
end

T["lifecycle"]["a directory that cannot be watched is logged once"] = function()
  child.lua([[
    _G.warns = 0
    local log = require("duet.log")
    local warn = log.warn
    log.warn = function(...) _G.warns = _G.warns + 1; return warn(...) end
    _G.new_fs_event = vim.uv.new_fs_event
    vim.uv.new_fs_event = function() return nil, "ENOSPC: no space left on device" end
    vim.cmd.edit(root .. '/a.txt')
    session()
    W.sync(); W.sync()
    vim.cmd.write()
    vim.wait(50)
  ]])
  eq(child.lua_get("warns"), 1)
  eq(child.lua_get("W._state().failed"), { dir })
  eq(child.lua_get("W._state().dirs"), {})
  child.lua("vim.uv.new_fs_event = new_fs_event; T.stop_all()")
  -- Watching again tries again.
  eq(child.lua_get("W._state().failed"), {})
  child.lua("session()")
  eq(child.lua_get("W._state().dirs"), { dir })
end

T["lifecycle disabled"] = function()
  start({ watch = { enabled = false } })
  child.lua("vim.cmd.edit(root .. '/a.txt'); session()")
  eq(child.lua_get("W._state()"), IDLE)
end

-- autoread ------------------------------------------------------------------------

T["autoread"] = MiniTest.new_set()

T["autoread"]["is turned on while watching and restored after"] = function()
  start()
  child.lua("vim.go.autoread = false; _G.s = session()")
  eq(child.lua_get("vim.go.autoread"), true)
  child.lua("s:stop()")
  eq(child.lua_get("vim.go.autoread"), false)
end

T["autoread"]["stays off if turned off while watching"] = function()
  start()
  child.lua("vim.go.autoread = false; _G.s = session(); vim.go.autoread = false; s:stop()")
  eq(child.lua_get("vim.go.autoread"), false)
end

T["autoread"]["keeps the value the user set while watching"] = function()
  start()
  child.lua("vim.go.autoread = false; _G.s = session(); vim.cmd('set noautoread'); vim.cmd('set autoread'); s:stop()")
  eq(child.lua_get("vim.go.autoread"), true)
end

T["autoread"]["is left on if it was on"] = function()
  start()
  child.lua("vim.go.autoread = true; _G.s = session(); s:stop()")
  eq(child.lua_get("vim.go.autoread"), true)
end

T["autoread"]["is left alone with watch.autoread = false"] = function()
  start({ watch = { autoread = false } })
  child.lua("vim.go.autoread = false; _G.s = session()")
  eq(child.lua_get("vim.go.autoread"), false)
  eq(child.lua_get("W._state().active"), true)
  child.lua("s:stop()")
  eq(child.lua_get("vim.go.autoread"), false)
end

-- Reloading -----------------------------------------------------------------------

T["reload"] = MiniTest.new_set()

T["reload"]["a file changed on disk updates its buffer within 1 s"] = function()
  start()
  child.lua("vim.cmd.edit(root .. '/a.txt'); _G.buf = vim.api.nvim_get_current_buf(); session()")
  child.lua("write(root .. '/a.txt', 'changed by the agent\\n')")
  eq(child.lua_get("wait(function() return lines(buf) == 'changed by the agent' end, 1000)"), true)
end

T["reload"]["a file replaced by a rename updates its buffer"] = function()
  start()
  child.lua("vim.cmd.edit(root .. '/a.txt'); _G.buf = vim.api.nvim_get_current_buf(); session()")
  child.lua("write(root .. '/a.txt.tmp', 'renamed over\\n'); assert(os.rename(root .. '/a.txt.tmp', root .. '/a.txt'))")
  eq(child.lua_get("wait(function() return lines(buf) == 'renamed over' end)"), true)
  -- The buffer still follows later writes.
  child.lua("write(root .. '/a.txt', 'written again\\n')")
  eq(child.lua_get("wait(function() return lines(buf) == 'written again' end)"), true)
end

T["reload"]["a buffer in another dir updates"] = function()
  start()
  child.lua("vim.cmd.edit(root .. '/sub/b.txt'); _G.buf = vim.api.nvim_get_current_buf(); session()")
  child.lua("write(root .. '/sub/b.txt', 'sub changed\\n')")
  eq(child.lua_get("wait(function() return lines(buf) == 'sub changed' end)"), true)
end

T["reload"]["a modified buffer is not overwritten"] = function()
  start()
  -- With a FileChangedShell autocmd, Neovim neither prompts nor reloads: it records why.
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved edit" })
    _G.reasons = {}
    vim.api.nvim_create_autocmd("FileChangedShell", {
      callback = function() table.insert(_G.reasons, vim.v.fcs_reason) end,
    })
    session()
    write(root .. '/a.txt', 'changed by the agent\n')
  ]])
  eq(child.lua_get("wait(function() return #reasons > 0 end)"), true)
  eq(child.lua_get("reasons"), { "conflict" })
  eq(child.lua_get("lines(buf)"), "unsaved edit")
  eq(child.lua_get("vim.bo[buf].modified"), true)
end

T["reload"]["a burst of writes is checked once"] = function()
  start({ watch = { debounce_ms = 200 } })
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    _G.reloads = 0
    vim.api.nvim_create_autocmd("FileChangedShellPost", {
      callback = function() _G.reloads = _G.reloads + 1 end,
    })
    session()
    write(root .. '/a.txt', 'x\n')
    write(root .. '/a.txt', 'xx\n')
    write(root .. '/a.txt', 'xxx\n')
  ]])
  eq(child.lua_get("wait(function() return lines(buf) == 'xxx' end)"), true)
  child.lua("vim.wait(300)")
  eq(child.lua_get("reloads"), 1)
end

T["reload"]["waits while the command line is open"] = function()
  start({ watch = { debounce_ms = 20 } })
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    session()
    _G.get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "c", blocking = false } end
    write(root .. '/a.txt', 'later\n')
  ]])
  child.lua("vim.wait(300)")
  eq(child.lua_get("lines(buf)"), "one")
  child.lua("vim.api.nvim_get_mode = get_mode")
  eq(child.lua_get("wait(function() return lines(buf) == 'later' end)"), true)
end

T["reload"]["leaving the agent terminal checks the files"] = function()
  -- A long debounce: only the TermLeave check can reload in time.
  start({ watch = { debounce_ms = 60000 } })
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    _G.s = session()
    write(root .. '/a.txt', 'seen on leave\n')
  ]])
  child.lua("vim.wait(200)")
  eq(child.lua_get("lines(buf)"), "one")
  child.lua("vim.api.nvim_exec_autocmds('TermLeave', { buffer = s.buf })")
  eq(child.lua_get("wait(function() return lines(buf) == 'seen on leave' end)"), true)
end

T["reload"]["a directory removed and created again is watched again"] = function()
  start()
  vim.fn.mkdir(dir .. "/gen", "p")
  vim.fn.writefile({ "generated" }, dir .. "/gen/x.txt")
  child.lua([[
    vim.cmd.edit(root .. '/gen/x.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    session()
    vim.fn.delete(root .. '/gen', 'rf')
    vim.fn.mkdir(root .. '/gen')
    write(root .. '/gen/x.txt', 'generated again\n')
  ]])
  eq(child.lua_get("wait(function() return lines(buf) == 'generated again' end)"), true)
  child.lua("vim.wait(200)")
  eq(child.lua_get("W._state().dirs"), { dir .. "/gen" })
  -- The new directory is watched.
  child.lua("write(root .. '/gen/x.txt', 'and changed later\\n')")
  eq(child.lua_get("wait(function() return lines(buf) == 'and changed later' end)"), true)
end

T["reload"]["while typing, only buffers that reload without asking are checked"] = function()
  start()
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.a = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "unsaved edit" })
    vim.cmd.edit(root .. '/sub/b.txt')
    _G.b = vim.api.nvim_get_current_buf()
    _G.reasons = {}
    vim.api.nvim_create_autocmd("FileChangedShell", {
      buffer = a,
      callback = function() table.insert(_G.reasons, vim.v.fcs_reason) end,
    })
    session()
    _G.get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "t", blocking = false } end
    write(root .. '/a.txt', 'changed by the agent\n')
    write(root .. '/sub/b.txt', 'b changed\n')
  ]])
  eq(child.lua_get("wait(function() return lines(b) == 'b changed' end)"), true)
  child.lua("vim.wait(200)")
  -- The modified buffer would prompt: it waits for the user to stop typing.
  eq(child.lua_get("reasons"), {})
  eq(child.lua_get("W._state().pending"), { dir })
  child.lua("vim.api.nvim_get_mode = get_mode; vim.api.nvim_exec_autocmds('ModeChanged', {})")
  eq(child.lua_get("wait(function() return #reasons > 0 end)"), true)
  eq(child.lua_get("reasons"), { "conflict" })
  eq(child.lua_get("lines(a)"), "unsaved edit")
end

T["reload"]["focus gained waits while the command line is open"] = function()
  start({ watch = { debounce_ms = 60000 } })
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    session()
    write(root .. '/a.txt', 'seen on focus\n')
    _G.get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "c", blocking = false } end
    vim.api.nvim_exec_autocmds('FocusGained', {})
  ]])
  child.lua("vim.wait(200)")
  eq(child.lua_get("lines(buf)"), "one")
  child.lua("vim.api.nvim_get_mode = get_mode; vim.api.nvim_exec_autocmds('ModeChanged', {})")
  eq(child.lua_get("wait(function() return lines(buf) == 'seen on focus' end)"), true)
end

T["reload"]["a check that fails is reported, not retried"] = function()
  -- Without 'autoread' the change goes to FileChangedShell, which fails here.
  start({ watch = { debounce_ms = 20, autoread = false } })
  child.lua([[
    vim.go.autoread = false
    vim.cmd.edit(root .. '/a.txt')
    _G.calls = 0
    vim.api.nvim_create_autocmd("FileChangedShell", {
      buffer = 0,
      callback = function() _G.calls = _G.calls + 1; error("boom") end,
    })
    session()
    write(root .. '/a.txt', 'changed by the agent\n')
  ]])
  eq(child.lua_get("wait(function() return calls > 0 end)"), true)
  child.lua("vim.wait(300)")
  eq(child.lua_get("calls"), 1)
  eq(child.lua_get("W._state().pending"), {})
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(notes[1].msg:match("watch: cannot check .*a%.txt: .*boom") ~= nil, true)
  eq(notes[1].level, vim.log.levels.WARN)
end

T["reload"]["nothing reloads once sessions stop"] = function()
  start()
  child.lua([[
    vim.cmd.edit(root .. '/a.txt')
    _G.buf = vim.api.nvim_get_current_buf()
    session():stop()
    write(root .. '/a.txt', 'unseen\n')
  ]])
  child.lua("vim.wait(300)")
  eq(child.lua_get("lines(buf)"), "one")
end

return T
