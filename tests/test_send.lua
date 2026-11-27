local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local P = "\27[200~"
local E = "\27[201~"

-- Pure functions ---------------------------------------------------------------

local T = MiniTest.new_set()

T["sanitize()"] = MiniTest.new_set({
  parametrize = {
    { "plain text", "hello world", "hello world" },
    { "keeps newlines and tabs", "a\n\tb\n", "a\n\tb\n" },
    { "CRLF to LF", "a\r\nb\r\n", "a\nb\n" },
    { "lone CR to LF", "a\rb", "a\nb" },
    { "removes NUL, BEL, backspace, DEL", "a\0b\7c\8d\127e", "abcde" },
    { "removes vertical tab, form feed, ^C, ^D, ^Z", "a\11\12\3\4\26b", "ab" },
    { "neutralises an early paste end", "x" .. E .. "\rrm -rf\r", "x[201~\nrm -rf\n" },
    { "removes ESC sequences' ESC", "\27[31mred\27[0m", "[31mred[0m" },
    { "removes C1 controls", "a\194\155b\194\128c\194\159d", "abcd" },
    { "keeps U+00A0 and later", "\194\160\194\169", "\194\160\194\169" },
    { "keeps multibyte text", "é Ж 🙂 漢字 ‘›’", "é Ж 🙂 漢字 ‘›’" },
    { "empty", "", "" },
  },
})

T["sanitize()"]["works"] = function(_, input, want)
  eq(require("duet.send").sanitize(input), want)
end

T["payload()"] = function()
  eq(require("duet.send").payload("a\nb"), P .. "a\nb" .. E)
end

T["writes()"] = MiniTest.new_set()

T["writes()"]["writes a short paste at once"] = function()
  eq(require("duet.send").writes("a\nb"), { P .. "a\nb" .. E })
end

T["writes()"]["writes a paste of exactly a chunk at once"] = function()
  local text = string.rep("x", 4096 - #P - #E)
  eq(require("duet.send").writes(text), { P .. text .. E })
end

T["writes()"]["puts the markers on their own in a longer paste"] = function()
  local text = string.rep("x", 4096 - #P - #E + 1)
  eq(require("duet.send").writes(text), { P, text, E })
end

T["writes()"]["never splits the end marker at a chunk boundary"] = function()
  -- In one payload, this length put the end marker's ESC at byte 4096.
  local text = string.rep("x", 4096 - #P - 1)
  eq(require("duet.send").writes(text), { P, text, E })
  eq(require("duet.send").writes(string.rep("y", 4097)), { P, string.rep("y", 4096), "y", E })
end

T["chunks()"] = MiniTest.new_set({
  parametrize = {
    { "empty", "", 4, {} },
    { "shorter than size", "abc", 4, { "abc" } },
    { "exactly size", "abcd", 4, { "abcd" } },
    { "splits", "abcdefghij", 4, { "abcd", "efgh", "ij" } },
    { "keeps a 2-byte character whole", "abcé", 4, { "abc", "é" } },
    { "keeps a 4-byte character whole", "ab🙂cd", 4, { "ab", "🙂", "cd" } },
    { "character longer than size", "🙂", 2, { "\240\159", "\153\130" } },
    { "size 1", "ab", 1, { "a", "b" } },
  },
})

T["chunks()"]["works"] = function(_, data, size, want)
  eq(require("duet.send").chunks(data, size), want)
end

T["probe()"] = MiniTest.new_set({
  parametrize = {
    { "a slash command", "/copy", "/copy" },
    { "the last word", "!echo duet-ok", "duet-ok" },
    { "trailing spaces", "fix the bug  ", "bug" },
    { "a long last word, cut", "see " .. string.rep("x", 40), string.rep("x", 16) },
    { "cut whole characters", string.rep("é", 10), string.rep("é", 8) },
    { "several lines", "one\ntwo", vim.NIL },
    { "a long text", string.rep("word ", 41), vim.NIL },
  },
})

T["probe()"]["works"] = function(_, text, want)
  local got = require("duet.send").probe(text)
  eq(got == nil and vim.NIL or got, want)
end

T["chunks()"]["joins back to the input"] = function()
  local send = require("duet.send")
  local parts = {}
  for i = 1, 500 do
    parts[i] = ("%d: aé🙂漢\n"):format(i)
  end
  local data = table.concat(parts)
  for _, size in ipairs({ 3, 4, 7, 64, 4096 }) do
    local chunks = send.chunks(data, size)
    eq(table.concat(chunks), data)
    for _, chunk in ipairs(chunks) do
      eq(#chunk <= size, true)
    end
  end
end

-- With a fake agent -------------------------------------------------------------

local child = h.new_child()
local out

-- The fake agent puts its tty in raw mode first, so the bytes duet writes reach it
-- unchanged (no echo, no CR to LF, no line length limit), then prints READY.
local AGENT = [[stty raw -echo; printf 'READY\r\n'; exec cat > "$OUT"]]

local function start()
  local dir = h.tmp_dir()
  out = dir .. "/out"
  local saved = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = dir
  child.restart({ "-u", "tests/minimal_init.lua" })
  vim.env.XDG_RUNTIME_DIR = saved
  child.o.columns, child.o.lines = 200, 50
  child.lua(
    [[
    _G.out = ...
    P, E = "\27[200~", "\27[201~"
    _G.notes = {}
    vim.notify = function(msg, level)
      table.insert(_G.notes, { msg = msg, level = level })
    end
    _G.writes = {}
    local chan_send = vim.api.nvim_chan_send
    vim.api.nvim_chan_send = function(chan, data)
      table.insert(_G.writes, data)
      return chan_send(chan, data)
    end
    -- Set _G.dialog to make the agent "ask something": not ready, whatever its output.
    _G.dialog = false
    _G.ready = function(_, lines)
      if _G.dialog then
        return false
      end
      for _, line in ipairs(lines) do
        if line:find("READY", 1, true) then
          return true
        end
      end
      return false
    end
    -- Register a fake agent running `script` with $OUT set, and make it the default.
    _G.fake = function(script, opts)
      require("duet.agents").register({
        name = "fake",
        cmd = { "sh", "-c", script },
        capabilities = { mcp = false, plan_hook = false, system_prompt = false },
        launch = function(self)
          return { argv = vim.deepcopy(self.cmd), env = { OUT = _G.out }, files = {} }
        end,
        is_ready = function(...)
          return _G.ready(...)
        end,
      })
      require("duet").setup(vim.tbl_deep_extend("force", { agent = "fake", send = { submit_delay_ms = 20 } }, opts or {}))
    end
    _G.read = function(path)
      local f = io.open(path, "rb")
      if not f then
        return nil
      end
      local data = f:read("*a")
      f:close()
      return data
    end
    _G.wait_out = function(want, ms)
      vim.wait(ms or 5000, function()
        return _G.read(_G.out) == want
      end, 10)
      return _G.read(_G.out)
    end
    -- Send and record what on_done got, in _G.done.
    _G.done = {}
    _G.send = function(text, opts)
      opts = opts or {}
      opts.on_done = function(err)
        table.insert(_G.done, err or "ok")
      end
      return require("duet").send(text, opts)
    end
    _G.wait_done = function(n, ms)
      vim.wait(ms or 5000, function()
        return #_G.done >= n
      end, 10)
      return _G.done
    end
  ]],
    { out }
  )
end

local function fake(script, opts)
  child.lua("_G.fake(...)", { script or AGENT, opts or {} })
end

local function wait_out(want, ms)
  return child.lua_get("_G.wait_out(...)", { want, ms })
end

local S = MiniTest.new_set({ hooks = { pre_case = start, post_once = child.stop } })
T["send()"] = S

S["writes the paste and the submit"] = function()
  fake()
  eq(child.lua_get("_G.send('first line\\nsecond line')"), true)
  eq(wait_out(P .. "first line\nsecond line" .. E .. "\r"), P .. "first line\nsecond line" .. E .. "\r")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
end

S["pastes without submitting"] = function()
  fake()
  child.lua("_G.send('draft', { submit = false })")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  eq(wait_out(P .. "draft" .. E), P .. "draft" .. E)
end

S["sanitizes the text"] = function()
  fake()
  child.lua("_G.send(...)", { "a\r\nb" .. E .. "\rc\3" })
  eq(wait_out(P .. "a\nb[201~\nc" .. E .. "\r"), P .. "a\nb[201~\nc" .. E .. "\r")
end

S["keeps sends in order"] = function()
  fake()
  child.lua([[
    _G.send("one")
    _G.send("two", { submit = false })
    _G.send("three")
  ]])
  local want = P .. "one" .. E .. "\r" .. P .. "two" .. E .. P .. "three" .. E .. "\r"
  eq(wait_out(want), want)
  eq(child.lua_get("_G.wait_done(3)"), { "ok", "ok", "ok" })
end

S["shows the bytes in a cat -v terminal"] = function()
  fake([[stty raw -echo; printf 'READY\r\n'; exec cat -v]])
  child.lua("_G.send('hi')")
  local want = "^[[200~hi^[[201~^M"
  eq(
    child.lua(
      [[local want = ...
      return vim.wait(5000, function()
        local s = require("duet.terminal").list()[1]
        return table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n"):find(want, 1, true) ~= nil
      end, 10)]],
      { want }
    ),
    true
  )
end

S["sends 100 KB in order, in chunks"] = function()
  fake()
  -- Start the agent first, so the big send is written at once.
  child.lua("_G.send('warm-up', { submit = false })")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  child.lua([[
    _G.writes, _G.done = {}, {}
    local lines, size, i = {}, 0, 0
    while size < 100 * 1024 do
      i = i + 1
      lines[i] = ("line %05d: äöü — 🙂 漢字\n"):format(i)
      size = size + #lines[i]
    end
    _G.big = table.concat(lines)
    _G.send(_G.big)
    _G.writes_at_return = #_G.writes
  ]])
  child.lua("_G.want = P .. 'warm-up' .. E .. require('duet.send').payload(_G.big) .. '\\r'")
  local want_len = child.lua_get("#_G.want")
  eq(#wait_out(child.lua_get("_G.want"), 10000), want_len)
  eq(child.lua_get("_G.read(_G.out) == _G.want"), true)
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  local writes = child.lua_get("vim.tbl_map(function(w) return #w end, _G.writes)")
  eq(#writes > 25, true)
  for _, n in ipairs(writes) do
    eq(n <= 4096, true)
  end
  -- send() returned after the first write: the rest went out on later loop turns.
  -- send() returned before writing anything: the writes went out on later loop turns.
  eq(child.lua_get("_G.writes_at_return"), 0)
  -- The markers went on their own; the last write is the submit.
  eq(child.lua_get("{ _G.writes[1], _G.writes[#_G.writes - 1], _G.writes[#_G.writes] }"), { P, E, "\r" })
end

S["starts the agent and waits until it is ready"] = function()
  fake([[stty raw -echo; sleep 0.4; printf 'READY\r\n'; exec cat > "$OUT"]])
  local win = child.api.nvim_get_current_win()
  eq(child.lua_get("_G.send('hello')"), true)
  eq(child.lua_get("#require('duet.terminal').list()"), 1)
  eq(child.lua_get("require('duet.terminal').list()[1]:is_visible()"), true)
  eq(child.api.nvim_get_current_win(), win)
  eq(child.lua_get("#_G.writes"), 0)
  eq(wait_out(P .. "hello" .. E .. "\r"), P .. "hello" .. E .. "\r")
  eq(child.lua_get("require('duet.terminal').list()[1].seen_ready"), true)
end

S["does not wait for an agent without is_ready"] = function()
  fake([[sleep 5]])
  child.lua([[
    local base = require("duet.agents").get("fake")
    require("duet.agents").register({
      name = "fake",
      cmd = base.cmd,
      capabilities = base.capabilities,
      launch = base.launch,
    })
  ]])
  child.lua("_G.send('now')")
  child.lua("vim.wait(1000, function() return #_G.writes >= 1 end, 5)")
  eq(child.lua_get("_G.writes[1]"), P .. "now" .. E)
end

S["waits while the agent is asking something"] = function()
  fake()
  child.lua("_G.send('one')")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  child.lua("_G.dialog = true; _G.writes = {}; _G.send('two'); vim.wait(300)")
  eq(child.lua_get("#_G.writes"), 0)
  child.lua("_G.dialog = false")
  local want = P .. "one" .. E .. "\r" .. P .. "two" .. E .. "\r"
  eq(wait_out(want), want)
  eq(child.lua_get("_G.wait_done(2)"), { "ok", "ok" })
end

S["fails when the agent keeps asking"] = function()
  fake(nil, { send = { ready_timeout_ms = 200 } })
  child.lua("_G.send('one')")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  child.lua("_G.dialog = true; _G.writes = {}; _G.send('two')")
  local done = child.lua_get("_G.wait_done(2)")
  eq(done[2]:find("fake is not ready for input after 200 ms", 1, true) ~= nil, true)
  eq(child.lua_get("#_G.writes"), 0)
end

S["pastes without submitting when a dialog opens before Enter"] = function()
  fake(nil, { send = { submit_delay_ms = 100 } })
  child.lua([[
    _G.send("x")
    _G.send("y")
    -- Open the dialog once the paste is written, during the submit delay, with the
    -- terminal hidden.
    vim.wait(3000, function() return vim.endswith(_G.writes[#_G.writes] or "", E) end, 5)
    _G.dialog = true
    require("duet.terminal").list()[1]:hide()
  ]])
  -- "y" is dropped: pasted after "x", it would be submitted together with it.
  local msg = "send: fake is asking something: the text was pasted but not submitted"
  eq(child.lua_get("_G.wait_done(2)"), { msg, msg })
  child.lua("_G.dialog = false; vim.wait(300)")
  eq(child.lua_get("_G.read(_G.out)"), P .. "x" .. E)
  -- The terminal is shown, so the user sees the dialog and the text left in the input.
  eq(child.lua_get("require('duet.terminal').list()[1]:is_visible()"), true)
end

S["submits when the agent looks busy only for a moment before Enter"] = function()
  fake(nil, { send = { submit_delay_ms = 50 } })
  child.lua([[
    _G.send("x")
    vim.wait(3000, function() return vim.endswith(_G.writes[#_G.writes] or "", E) end, 5)
    -- A redraw: the input box is off screen for less than the grace period.
    _G.dialog = true
    vim.defer_fn(function() _G.dialog = false end, 200)
  ]])
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  eq(wait_out(P .. "x" .. E .. "\r"), P .. "x" .. E .. "\r")
end

S["submits a slash command while Claude Code's command menu is open"] = function()
  -- Claude Code's screens and readiness rule: the input box, then (once the paste has
  -- arrived) a cleared screen with the box holding `/clear` and the command menu below
  -- it. The test checks that Enter went through on the menu's screen.
  local rule = string.rep("─", 60)
  local box = ("printf '%%s\\r\\n' '%s' '❯ ' '%s'"):format(rule, rule)
  local menu = ("printf '\\033[2J\\033[H'; printf '%%s\\r\\n' '%s' '❯\194\160/clear' '%s' '  ❯ /clear    Start a new session'"):format(
    rule,
    rule
  )
  local paste = #(P .. "/clear" .. E)
  fake(
    ([[stty raw -echo; %s; dd bs=1 count=%d of="$OUT" 2>/dev/null; %s; exec cat >> "$OUT"]]):format(box, paste, menu),
    {
      -- Long enough for the menu to be on screen before Enter.
      send = { submit_delay_ms = 300 },
    }
  )
  child.lua([[
    local claude = require("duet.agents").get("claude")
    -- Whether the last check (the one before Enter) saw the menu.
    _G.saw_menu = false
    _G.ready = function(_, lines)
      _G.saw_menu = table.concat(lines, "\n"):find("❯ /clear    Start", 1, true) ~= nil
      return claude:is_ready(lines)
    end
  ]])
  child.lua("_G.send('/clear')")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  eq(child.lua_get("_G.read(_G.out)"), P .. "/clear" .. E .. "\r")
  eq(child.lua_get("_G.saw_menu"), true)
end

-- Give the fake agent a read_input: the last line that starts with ">", its input box.
-- Each write records what that box showed when it was written, in _G.seen.
local function with_read_input()
  child.lua([[
    local base = require("duet.agents").get("fake")
    _G.read_input = function(_, lines)
      for i = #lines, 1, -1 do
        if vim.startswith(lines[i], ">") then
          return lines[i]
        end
      end
      return nil
    end
    require("duet.agents").register({
      name = "fake",
      cmd = base.cmd,
      capabilities = base.capabilities,
      launch = base.launch,
      is_ready = base.is_ready,
      read_input = function(...)
        return _G.read_input(...)
      end,
    })
    _G.seen = {}
    local chan_send = vim.api.nvim_chan_send
    vim.api.nvim_chan_send = function(chan, data)
      local s = require("duet.terminal").list()[1]
      table.insert(_G.seen, { data, s and s:input() or vim.NIL })
      return chan_send(chan, data)
    end
  ]])
end

S["waits for the agent to show the paste and take Enter in"] = function()
  -- An agent slow to draw, as Claude Code is while it starts: it shows each paste in its
  -- input box (the last ">" line) 0.4 s after reading it, and clears the box 0.4 s after
  -- reading Enter.
  local paste = #(P .. "/copy" .. E)
  local step = (
    [[dd bs=1 count=%d >> "$OUT" 2>/dev/null; sleep 0.4; printf '> /copy\r\n'; ]]
    .. [[dd bs=1 count=1 >> "$OUT" 2>/dev/null; sleep 0.4; printf '>\r\n']]
  ):format(paste)
  fake(([[stty raw -echo; printf 'READY\r\n>\r\n'; %s; %s; exec cat >> "$OUT"]]):format(step, step))
  with_read_input()
  child.lua("_G.send('/copy'); _G.send('/copy')")
  eq(child.lua_get("_G.wait_done(2)"), { "ok", "ok" })
  local want = P .. "/copy" .. E .. "\r" .. P .. "/copy" .. E .. "\r"
  eq(wait_out(want), want)
  -- Enter went in once the paste showed, and the next paste once the box was cleared.
  eq(child.lua_get("_G.seen"), {
    { P .. "/copy" .. E, ">" },
    { "\r", "> /copy" },
    { P .. "/copy" .. E, ">" },
    { "\r", "> /copy" },
  })
end

S["presses Enter anyway when the paste never shows"] = function()
  fake()
  with_read_input()
  child.lua([[
    require("duet.send").SUBMIT_GRACE_MS = 200
    _G.read_input = function() return "> unchanged" end
    _G.send("x")
  ]])
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  eq(wait_out(P .. "x" .. E .. "\r"), P .. "x" .. E .. "\r")
end

S["goes on when the input does not change after Enter"] = function()
  fake()
  with_read_input()
  child.lua([[
    require("duet.send").SUBMIT_SETTLE_MS = 300
    -- The box shows each paste, and keeps it after Enter.
    _G.box = "> "
    _G.read_input = function() return _G.box end
    local chan_send = vim.api.nvim_chan_send
    _G.at = {}
    vim.api.nvim_chan_send = function(chan, data)
      table.insert(_G.at, vim.uv.now())
      if data ~= "\r" then
        _G.box = "> " .. data
      end
      return chan_send(chan, data)
    end
    _G.send("one")
    _G.send("two")
  ]])
  eq(child.lua_get("_G.wait_done(2)"), { "ok", "ok" })
  local want = P .. "one" .. E .. "\r" .. P .. "two" .. E .. "\r"
  eq(wait_out(want), want)
  -- The second paste waited for the settle time after the first Enter.
  eq(child.lua_get("_G.at[3] - _G.at[2] >= 300"), true)
end

S["sends without waiting when read_input fails"] = function()
  fake()
  with_read_input()
  child.lua([[
    _G.read_input = function() error("boom") end
    _G.t0 = vim.uv.now()
    _G.send("x")
    _G.send("y")
  ]])
  eq(child.lua_get("_G.wait_done(2)"), { "ok", "ok" })
  local want = P .. "x" .. E .. "\r" .. P .. "y" .. E .. "\r"
  eq(wait_out(want), want)
  -- Neither the grace time nor the settle time was waited out.
  eq(child.lua_get("vim.uv.now() - _G.t0 < 1500"), true)
end

S["does not take a redraw for the paste"] = function()
  fake()
  with_read_input()
  child.lua([[
    -- Once the paste is written, the box first redraws with other text, then shows the
    -- paste 300 ms later.
    _G.box = "> "
    _G.read_input = function() return _G.box end
    local chan_send = vim.api.nvim_chan_send
    vim.api.nvim_chan_send = function(chan, data)
      -- Written (and recorded in _G.seen) before the box changes.
      chan_send(chan, data)
      if data == "\r" then
        _G.box = "> "
      else
        _G.box = '> Try "something"'
        vim.defer_fn(function() _G.box = "> /copy" end, 300)
      end
    end
    _G.send("/copy")
  ]])
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  eq(child.lua_get("_G.seen[2]"), { "\r", "> /copy" })
end

S["waits the whole settle time when the paste showed late"] = function()
  fake()
  with_read_input()
  child.lua([[
    local send = require("duet.send")
    send.SUBMIT_GRACE_MS, send.SUBMIT_SETTLE_MS = 200, 600
    -- The box shows each paste 400 ms after it is written (after the grace time), and
    -- never clears it.
    _G.box = "> "
    _G.read_input = function() return _G.box end
    _G.at = {}
    local chan_send = vim.api.nvim_chan_send
    vim.api.nvim_chan_send = function(chan, data)
      table.insert(_G.at, vim.uv.now())
      if data ~= "\r" then
        vim.defer_fn(function() _G.box = "> " .. data end, 400)
      end
      return chan_send(chan, data)
    end
    _G.send("one")
    _G.send("two")
  ]])
  eq(child.lua_get("_G.wait_done(2)"), { "ok", "ok" })
  eq(child.lua_get("_G.at[3] - _G.at[2] >= 600"), true)
end

S["shows a hidden agent that is asking something"] = function()
  fake()
  child.lua([[
    _G.s = assert(require("duet.terminal").ensure())
    vim.wait(3000, function() return _G.s:is_ready() end, 10)
    _G.dialog = true
    _G.win = vim.api.nvim_get_current_win()
    _G.visible_before = _G.s:is_visible()
    _G.send("z")
  ]])
  eq(child.lua_get("_G.visible_before"), false)
  eq(child.lua_get("vim.wait(1000, function() return _G.s:is_visible() end, 10)"), true)
  eq(child.lua_get("vim.api.nvim_get_current_win() == _G.win"), true)
  child.lua("_G.dialog = false")
  eq(wait_out(P .. "z" .. E .. "\r"), P .. "z" .. E .. "\r")
end

S["calls on_done after send() returns, even for an early error"] = function()
  fake()
  child.lua([[
    _G.s = assert(require("duet.terminal").ensure())
    _G.ready = function() error("boom") end
    _G.r = _G.send("x")
    _G.at_return = #_G.done
  ]])
  eq(child.lua_get("{ _G.r, _G.at_return }"), { true, 0 })
  local done = child.lua_get("_G.wait_done(1)")
  eq(done[1]:find("fake is_ready failed: .*boom") ~= nil, true)
end

S["fails queued sends when the agent is stopped"] = function()
  fake()
  child.lua("_G.send('one')")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  child.lua([[
    _G.dialog = true
    _G.send("two")
    _G.send("three")
    require("duet.terminal").list()[1]:stop()
  ]])
  eq(child.lua_get("_G.wait_done(3)"), { "ok", "terminal: fake was stopped", "terminal: fake was stopped" })
end

S["fails queued sends when the agent dies"] = function()
  fake()
  child.lua("_G.send('one')")
  eq(child.lua_get("_G.wait_done(1)"), { "ok" })
  child.lua([[
    _G.dialog = true
    _G.send("two")
    vim.fn.jobstop(require("duet.terminal").list()[1].job)
  ]])
  eq(child.lua_get("_G.wait_done(2)"), { "ok", "terminal: fake exited" })
end

S["shows an exit not seen yet instead of restarting"] = function()
  fake(
    [[if [ -e "$OUT.started" ]; then stty raw -echo; printf 'READY\r\n'; exec cat > "$OUT"; fi; touch "$OUT.started"; exit 3]]
  )
  child.lua([[
    _G.first = assert(require("duet.terminal").ensure())
    vim.wait(3000, function() return not _G.first:is_running() end, 10)
  ]])
  eq(child.lua_get("{ _G.first:is_running(), _G.first:is_visible() }"), { false, false })
  eq(
    child.lua_get("{ require('duet').send('hi') }"),
    { vim.NIL, "terminal: fake exited: see its terminal, then try again" }
  )
  eq(child.lua_get("{ _G.first:is_visible(), #require('duet.terminal').list() }"), { true, 1 })
  -- Seen now: the next send restarts the agent.
  eq(child.lua_get("_G.send('hi')"), true)
  eq(wait_out(P .. "hi" .. E .. "\r"), P .. "hi" .. E .. "\r")
end

S["reports a failure to show an exit not seen yet"] = function()
  fake([[exit 3]])
  child.lua([[
    _G.first = assert(require("duet.terminal").ensure())
    vim.wait(3000, function() return not _G.first:is_running() end, 10)
    _G.first.show = function()
      return nil, "terminal: cannot open window: boom"
    end
  ]])
  eq(child.lua_get("{ require('duet').send('hi') }"), { vim.NIL, "terminal: cannot open window: boom" })
  eq(child.lua_get("_G.first.exit_seen"), false)
  -- Once it can be shown, it is shown first instead of being restarted.
  child.lua("_G.first.show = nil")
  eq(
    child.lua_get("{ require('duet').send('hi') }"),
    { vim.NIL, "terminal: fake exited: see its terminal, then try again" }
  )
  eq(child.lua_get("{ _G.first:is_visible(), _G.first.exit_seen }"), { true, true })
end

S["finds the prompt above many blank lines"] = function()
  -- READY, then 300 blank rows, as on a very tall terminal.
  fake(
    [[stty raw -echo; printf 'READY\r\n'; i=0; while [ $i -lt 300 ]; do printf '\r\n'; i=$((i+1)); done; exec cat > "$OUT"]]
  )
  child.lua("_G.send('tall')")
  eq(wait_out(P .. "tall" .. E .. "\r"), P .. "tall" .. E .. "\r")
end

S["focuses the terminal with focus = true"] = function()
  fake()
  child.lua("_G.send('x', { focus = true })")
  eq(child.lua_get("vim.api.nvim_get_current_buf() == require('duet.terminal').list()[1].buf"), true)
end

S["restarts an exited agent"] = function()
  -- The first run exits at once; the restart behaves as an agent.
  fake(
    [[if [ -e "$OUT.started" ]; then stty raw -echo; printf 'READY\r\n'; exec cat > "$OUT"; fi; touch "$OUT.started"]],
    { terminal = { close_on_exit = "never" } }
  )
  child.lua([[
    _G.first = assert(require("duet.terminal").open())
    vim.wait(3000, function() return not _G.first:is_running() end, 10)
  ]])
  eq(child.lua_get("_G.first:is_running()"), false)
  child.lua("_G.send('again')")
  eq(wait_out(P .. "again" .. E .. "\r"), P .. "again" .. E .. "\r")
  eq(child.lua_get("require('duet.terminal').list()[1] ~= _G.first"), true)
end

S["fails when the agent is never ready"] = function()
  fake([[stty raw -echo; exec cat > "$OUT"]], { send = { ready_timeout_ms = 200 } })
  child.lua("_G.send('a'); _G.send('b')")
  local done = child.lua_get("_G.wait_done(2)")
  eq(#done, 2)
  MiniTest.expect.equality(done[1]:find("fake is not ready for input after 200 ms", 1, true) ~= nil, true)
  eq(done[2], done[1])
  eq(child.lua_get("#_G.writes"), 0)
end

S["notifies once when sends without on_done fail"] = function()
  fake([[stty raw -echo; exec cat > "$OUT"]], { send = { ready_timeout_ms = 100 } })
  child.lua("require('duet').send('a'); require('duet').send('b')")
  child.lua("vim.wait(3000, function() return #_G.notes > 0 end, 10); vim.wait(200)")
  local notes = child.lua_get("_G.notes")
  eq(#notes, 1)
  eq(notes[1].level, vim.log.levels.ERROR)
  eq(notes[1].msg:find("not ready for input", 1, true) ~= nil, true)
end

S["fails when the agent exits before it is ready"] = function()
  fake([[sleep 0.2; exit 0]])
  child.lua("_G.send('a')")
  local done = child.lua_get("_G.wait_done(1)")
  eq(done[1]:find("fake exited before it was ready", 1, true) ~= nil, true)
end

S["rejects empty text"] = function()
  fake()
  eq(child.lua_get("{ require('duet').send(' \\n\\27 ') }"), { vim.NIL, "send: nothing to send" })
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
end

S["rejects a session that is not running"] = function()
  fake([[exit 0]], { terminal = { close_on_exit = "never" } })
  child.lua([[
    _G.s = assert(require("duet.terminal").open())
    vim.wait(3000, function() return not _G.s:is_running() end, 10)
  ]])
  eq(child.lua_get("{ require('duet').send('x', { session = _G.s }) }"), { vim.NIL, "send: fake is not running" })
end

local C = MiniTest.new_set({ hooks = { pre_case = start, post_once = child.stop } })
T[":Duet"] = C

C["send submits the raw text"] = function()
  fake()
  child.cmd("Duet send fix  this, please")
  eq(wait_out(P .. "fix  this, please" .. E .. "\r"), P .. "fix  this, please" .. E .. "\r")
end

C["send! only pastes"] = function()
  fake()
  child.cmd("Duet! send draft")
  eq(wait_out(P .. "draft" .. E), P .. "draft" .. E)
  child.lua("vim.wait(100)")
  eq(child.lua_get("_G.read(_G.out)"), P .. "draft" .. E)
end

C["send without text shows usage"] = function()
  fake()
  child.cmd("Duet send")
  eq(child.lua_get("_G.notes[1].msg"), "[duet] send: usage: :Duet send <text>")
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
end

C["prompt sends what was typed"] = function()
  fake()
  child.lua([[
    vim.ui.input = function(opts, cb)
      _G.input_opts = opts
      cb("typed text")
    end
  ]])
  child.cmd("Duet prompt start")
  eq(child.lua_get("_G.input_opts"), { prompt = "duet> ", default = "start" })
  eq(wait_out(P .. "typed text" .. E .. "\r"), P .. "typed text" .. E .. "\r")
end

---Open `a.lua` with three lines in a temporary project, as the current buffer.
local function code()
  child.lua([[
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd.cd(dir)
    vim.cmd.edit("a.lua")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1", "local b = 2", "return a + b" })
    vim.bo.filetype = "lua"
  ]])
end

C["send expands the selection"] = function()
  fake()
  code()
  child.type_keys("j", "V", "j", ":", "Duet send Refactor {selection}<CR>")
  local want = P .. "Refactor\na.lua:L2-L3\n```lua\nlocal b = 2\nreturn a + b\n```" .. E .. "\r"
  eq(wait_out(want), want)
end

C["send expands a character-wise selection"] = function()
  fake()
  code()
  child.lua([[vim.keymap.set("x", "<F5>", "<Cmd>Duet send What is {selection}?<CR>")]])
  child.api.nvim_win_set_cursor(0, { 3, 7 })
  child.type_keys("v", "$", "h", "<F5>")
  local want = P .. "What is\na.lua:L3\n```lua\na + b\n```\n?" .. E .. "\r"
  eq(wait_out(want), want)
  eq(child.fn.mode(), "n")
end

C["send with a typed range sends whole lines, whatever was selected before"] = function()
  fake()
  code()
  child.api.nvim_win_set_cursor(0, { 2, 6 })
  child.type_keys("v", "j", "<Esc>")
  child.cmd("2,3Duet send {selection}")
  local want = P .. "a.lua:L2-L3\n```lua\nlocal b = 2\nreturn a + b\n```" .. E .. "\r"
  eq(wait_out(want), want)
end

C["send expands inline placeholders and leaves unknown ones"] = function()
  fake()
  code()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Duet send Look at {this} in {file}, not {foo}")
  local want = P .. "Look at a.lua:L2 in a.lua, not {foo}" .. E .. "\r"
  eq(wait_out(want), want)
end

C["send refuses when every placeholder is empty"] = function()
  fake()
  code()
  child.cmd("Duet send Refactor {selection}")
  eq(
    child.lua_get("_G.notes[1].msg"),
    "[duet] send: nothing to send: {selection} is empty (no range or selection given: use :'<,'> or a visual-mode mapping)"
  )
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
end

C["send warns about a failed provider and sends the rest"] = function()
  fake()
  code()
  child.lua([[require("duet.context").register("broken", function() error("oops") end)]])
  child.cmd("Duet send Review {file} {broken}")
  eq(wait_out(P .. "Review a.lua" .. E .. "\r"), P .. "Review a.lua" .. E .. "\r")
  local note = child.lua_get("_G.notes[1]")
  eq(note.level, vim.log.levels.WARN)
  eq(note.msg:match("^%[duet%] send: {broken} failed: .*oops$") ~= nil, true)
end

C["ask reports a failed provider"] = function()
  fake(nil, { prompts = { mine = "Do {broken}" } })
  code()
  child.lua([[require("duet.context").register("broken", function() error("oops") end)]])
  child.cmd("Duet ask mine")
  eq(
    child.lua_get("_G.notes[1].msg"):match("^%[duet%] ask: mine: nothing to send: {broken} failed: .*oops$") ~= nil,
    true
  )
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
end

C["send from a tab with only the agent's terminal sends no selection"] = function()
  fake()
  child.lua([[
    assert(require("duet.terminal").open())
    vim.cmd("only")
    vim.cmd.stopinsert()
  ]])
  child.cmd("1,1Duet send Refactor {selection}")
  eq(
    child.lua_get("_G.notes[#_G.notes].msg"),
    "[duet] send: nothing to send: {selection} is empty (no range or selection given: use :'<,'> or a visual-mode mapping)"
  )
  child.lua("vim.wait(200)")
  -- The agent created its output file when it started; nothing was written to it.
  eq(child.lua_get("_G.read(_G.out) or ''"), "")
end

C["prompt expands what was typed, with the context from before the input"] = function()
  fake()
  code()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.lua([[
    vim.ui.input = function(_, cb)
      -- The window changes while the input is open.
      vim.cmd("new")
      cb("Explain {this}")
    end
  ]])
  child.cmd("Duet prompt")
  eq(wait_out(P .. "Explain a.lua:L3" .. E .. "\r"), P .. "Explain a.lua:L3" .. E .. "\r")
end

C["ask sends a prompt template"] = function()
  fake()
  code()
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.cmd("Duet ask explain")
  eq(wait_out(P .. "Explain a.lua:L2" .. E .. "\r"), P .. "Explain a.lua:L2" .. E .. "\r")
end

C["ask! only pastes, and uses the range"] = function()
  fake()
  code()
  child.lua([[
    local ns = vim.api.nvim_create_namespace("t")
    vim.diagnostic.set(ns, 0, {
      { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "outside" },
      { lnum = 2, col = 0, severity = vim.diagnostic.severity.WARN, message = "inside" },
    })
  ]])
  child.cmd("2,3Duet! ask fix")
  eq(wait_out(P .. "Fix\na.lua:3: [WARN] inside" .. E), P .. "Fix\na.lua:3: [WARN] inside" .. E)
end

C["ask uses prompts from the config"] = function()
  fake(nil, { prompts = { tests = "Write tests for {file}", explain = false } })
  code()
  child.cmd("Duet ask tests")
  eq(wait_out(P .. "Write tests for a.lua" .. E .. "\r"), P .. "Write tests for a.lua" .. E .. "\r")
  child.cmd("Duet ask explain")
  eq(child.lua_get("_G.notes[#_G.notes].msg"), "[duet] ask: unknown prompt 'explain' (available: fix, review, tests)")
end

C["ask without a name picks one"] = function()
  fake()
  code()
  child.lua([[
    vim.ui.select = function(items, opts, cb)
      _G.picked = { items = items, prompt = opts.prompt, first = opts.format_item(items[1]) }
      cb("review")
    end
  ]])
  child.cmd("Duet ask")
  eq(
    child.lua_get("_G.picked"),
    { items = { "explain", "fix", "review" }, prompt = "duet ask", first = "explain: Explain {this}" }
  )
  eq(wait_out(P .. "Review a.lua" .. E .. "\r"), P .. "Review a.lua" .. E .. "\r")
end

C["ask sends nothing when the picker is cancelled"] = function()
  fake()
  code()
  child.lua("vim.ui.select = function(_, _, cb) cb(nil) end")
  child.cmd("Duet ask")
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
  eq(child.lua_get("_G.notes"), {})
end

C["ask reports errors"] = function()
  fake()
  code()
  child.cmd("Duet ask nope")
  eq(child.lua_get("_G.notes[1].msg"), "[duet] ask: unknown prompt 'nope' (available: explain, fix, review)")
  child.cmd("Duet ask fix now")
  eq(child.lua_get("_G.notes[2].msg"), "[duet] ask: usage: :Duet ask [name]")
  child.cmd("Duet ask fix")
  eq(child.lua_get("_G.notes[3].msg"), "[duet] ask: fix: nothing to send: {diagnostics} is empty")
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
end

C["ask completes prompt names"] = function()
  fake()
  eq(child.fn.getcompletion("Duet ask ", "cmdline"), { "explain", "fix", "review" })
  eq(child.fn.getcompletion("Duet ask f", "cmdline"), { "fix" })
  eq(child.fn.getcompletion("Duet ask fix ", "cmdline"), {})
end

C["duet.ask() from visual mode sends the selection and leaves visual mode"] = function()
  fake(nil, { prompts = { refactor = "Refactor {selection}" } })
  code()
  child.lua([[
    vim.keymap.set("x", "<F4>", function()
      _G.r = { require("duet").ask("refactor") }
    end)
  ]])
  child.type_keys("V", "<F4>")
  eq(child.lua_get("_G.r"), { true })
  eq(child.fn.mode(), "n")
  local want = P .. "Refactor\na.lua:L1\n```lua\nlocal a = 1\n```" .. E .. "\r"
  eq(wait_out(want), want)
end

C["duet.render() expands without sending"] = function()
  fake()
  code()
  eq(
    child.lua_get("{ require('duet').render('{file} {foo}') }"),
    { "a.lua {foo}", { used = { "file" }, empty = {}, errors = vim.empty_dict() } }
  )
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
end

C["prompt sends nothing when cancelled"] = function()
  fake()
  child.lua("vim.ui.input = function(_, cb) cb(nil) end")
  child.cmd("Duet prompt")
  eq(child.lua_get("#require('duet.terminal').list()"), 0)
  eq(child.lua_get("_G.notes"), {})
end

return T
