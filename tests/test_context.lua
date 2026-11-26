local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.reset_modules()
    end,
  },
})

-- render() ----------------------------------------------------------------------

---Register fake providers: `word` (inline), `code` (block), `none` (nil), `blank`
---(whitespace), `boom` (throws), `bad` (wrong type), `braces` (text with placeholders).
local function fakes()
  local context = require("duet.context")
  context.register("word", function()
    return { text = "WORD", data = {} }
  end)
  context.register("code", function()
    return { text = "```\nx = 1\n```", data = {}, block = true }
  end)
  context.register("none", function()
    return nil
  end)
  context.register("blank", function()
    return { text = "  \n", data = {} }
  end)
  context.register("boom", function()
    error("broken")
  end)
  context.register("bad", function()
    return "text"
  end)
  context.register("braces", function()
    return { text = "{word} {file}", data = {} }
  end)
  return context
end

T["render()"] = MiniTest.new_set()

T["render()"]["cases"] = MiniTest.new_set({
  parametrize = {
    { "no placeholders", "plain text", "plain text", {}, {} },
    { "inline", "Explain {word} now", "Explain WORD now", { "word" }, {} },
    { "repeated placeholder", "{word} and {word}", "WORD and WORD", { "word" }, {} },
    { "unknown name is left as typed", "fix {foo} and {word}", "fix {foo} and WORD", { "word" }, {} },
    { "braces that are not names", "map {} and { a = 1 } {x-y}", "map {} and { a = 1 } {x-y}", {}, {} },
    { "nil provider renders empty", "a{none}b", "ab", { "none" }, { "none" } },
    { "blank text counts as empty", "a{blank}b", "ab", { "blank" }, { "blank" } },
    { "failing provider renders empty", "a{boom}b", "ab", { "boom" }, { "boom" } },
    { "malformed result renders empty", "a{bad}b", "ab", { "bad" }, { "bad" } },
    { "drops a line left blank", "Fix:\n{none}\nthanks", "Fix:\nthanks", { "none" }, { "none" } },
    { "drops a line left with spaces", "a\n  {none}  \nb", "a\nb", { "none" }, { "none" } },
    { "keeps blank lines that were blank", "a\n\n{word}\n", "a\n\nWORD\n", { "word" }, {} },
    { "provider text is not expanded again", "{braces}", "{word} {file}", { "braces" }, {} },
    { "block alone on its line", "{code}", "```\nx = 1\n```", { "code" }, {} },
    {
      "block after text goes on its own line",
      "Refactor {code}",
      "Refactor\n```\nx = 1\n```",
      { "code" },
      {},
    },
    {
      "text after a block starts a new line",
      "See {code} and {word}",
      "See\n```\nx = 1\n```\nand WORD",
      { "code", "word" },
      {},
    },
    { "two blocks on one line", "{code} {code}", "```\nx = 1\n```\n```\nx = 1\n```", { "code" }, {} },
    { "used in order of first use", "{none} {word} {none}", "WORD", { "none", "word" }, { "none" } },
    {
      "empty at the start drops the space after it",
      "{none} tail {word}",
      "tail WORD",
      { "none", "word" },
      { "none" },
    },
    { "empty in the middle leaves one space", "a {none} b", "a b", { "none" }, { "none" } },
    { "empty after indentation keeps it", "  - {none} b", "  - b", { "none" }, { "none" } },
    { "empty glued to text keeps the space", "a{none} b", "a b", { "none" }, { "none" } },
    { "empty at the end drops trailing spaces", "Fix {none}", "Fix", { "none" }, { "none" } },
    { "lines without placeholders keep their spaces", "  keep  \n{word}", "  keep  \nWORD", { "word" }, {} },
  },
})

T["render()"]["cases"]["work"] = function(_, template, want, used, empty)
  local context = fakes()
  local text, info = context.render(template, {})
  eq(text, want)
  eq({ info.used, info.empty }, { used, empty })
end

T["render()"]["records why providers failed"] = function()
  local _, info = fakes().render("{boom} {bad} {none} {word}", {})
  eq(vim.tbl_keys(info.errors), vim.tbl_keys({ boom = true, bad = true }))
  eq(info.errors.boom:match("^{boom} failed: .*broken$") ~= nil, true)
  eq(info.errors.bad, '{bad} returned "text", expected { text, data } or nil')
  eq(info.empty, { "boom", "bad", "none" })
end

T["render()"]["calls each provider once"] = function()
  local context = require("duet.context")
  local calls = 0
  context.register("count", function()
    calls = calls + 1
    return { text = "n", data = {} }
  end)
  eq(context.render("{count}{count}\n{count}", {}), "nn\nn")
  eq(calls, 1)
end

T["render()"]["leaves an unregistered built-in as typed"] = function()
  local context = require("duet.context")
  context.unregister("file")
  eq(context.render("Review {file}", {}), "Review {file}")
  eq(vim.tbl_contains(context.names(), "file"), false)
end

T["expand()"] = MiniTest.new_set()

T["expand()"]["cases"] = MiniTest.new_set({
  parametrize = {
    { "no placeholders", "hello", { text = "hello" } },
    { "some empty", "{word} {none}", { text = "WORD" } },
    { "all empty", "Refactor {none}", { err = "nothing to send: {none} is empty" } },
    { "several empty", "{none} {blank}", { err = "nothing to send: {none}, {blank} are empty" } },
    { "unknown only", "{foo}", { text = "{foo}" } },
    {
      "only a failed provider",
      "Fix {bad}",
      { err = 'nothing to send: {bad} returned "text", expected { text, data } or nil' },
    },
    {
      "failures named before empty ones",
      "{none} {bad}",
      { err = 'nothing to send: {bad} returned "text", expected { text, data } or nil; {none} is empty' },
    },
    {
      "a failure next to content is a warning",
      "{word} {bad}",
      { text = "WORD", warning = '{bad} returned "text", expected { text, data } or nil' },
    },
  },
})

T["expand()"]["cases"]["work"] = function(_, template, want)
  local text, err, warning = fakes().expand(template, {})
  eq({ text = text, err = err, warning = warning }, want)
end

T["expand()"]["hints at a missing selection"] = function()
  local _, err = require("duet.context").expand("Refactor {selection}", { buf = 0 })
  eq(err, "nothing to send: {selection} is empty (no range or selection given; duet.send() sends text as typed)")
end

T["register()"] = MiniTest.new_set()

T["register()"]["rejects bad names"] = function()
  local context = require("duet.context")
  for _, name in ipairs({ "", "a b", "a-b", "{x}" }) do
    MiniTest.expect.error(function()
      context.register(name, function() end)
    end)
  end
end

T["register()"]["replaces a built-in"] = function()
  local context = require("duet.context")
  context.register("file", function()
    return { text = "mine", data = {} }
  end)
  eq(context.render("{file}", {}), "mine")
end

T["names()"] = function()
  local context = require("duet.context")
  context.register("zz", function() end)
  eq(context.names(), { "buffers", "diagnostics", "diagnostics_all", "file", "quickfix", "selection", "this", "zz" })
end

T["location()"] = MiniTest.new_set({
  parametrize = {
    { "file", { path = "a.lua" }, "a.lua" },
    { "one line", { path = "a.lua", range = { 3, 3 } }, "a.lua:L3" },
    { "lines", { path = "a.lua", range = { 3, 9 } }, "a.lua:L3-L9" },
  },
})

T["location()"]["works"] = function(_, args, want)
  eq(require("duet.context").location(args.path, args.range), want)
end

T["truncate() and list_text()"] = function()
  local context = require("duet.context")
  context.MAX_ITEMS = 2
  local kept, dropped = context.truncate({ "a", "b", "c", "d" })
  eq({ kept, dropped }, { { "a", "b" }, 2 })
  eq(context.list_text(kept, dropped), "a\nb\n… and 2 more")
  eq({ context.truncate({ "a" }) }, { { "a" }, 0 })
  eq(context.list_text({ "a" }, 0), "a")
end

T["fence()"] = MiniTest.new_set({
  parametrize = {
    { "plain", "x = 1", "```" },
    { "inline backticks", "use `x` here", "```" },
    { "a fence inside", "```lua\nx\n```", "````" },
    { "a long fence inside", "`````", "``````" },
  },
})

T["fence()"]["works"] = function(_, text, want)
  eq(require("duet.context.providers.selection").fence(text), want)
end

-- Providers on fixture buffers ----------------------------------------------------

local root

---A buffer for `root/<name>` with `lines` and filetype `ft`, shown in the current window.
local function fixture(name, lines, ft)
  local path = vim.fs.joinpath(root, name)
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or ""
  vim.bo[buf].modified = false
  return buf
end

local function ctx_for(buf, extra)
  return vim.tbl_extend("force", {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    cursor = { 1, 0 },
    cwd = root,
  }, extra or {})
end

local function lines_range(s, e)
  return { start_line = s, end_line = e, mode = "line" }
end

local ns

local P = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.reset_modules()
      root = h.tmp_dir()
      ns = vim.api.nvim_create_namespace("duet-test")
      vim.diagnostic.reset()
      vim.fn.setqflist({}, "f")
      vim.cmd("silent! %bwipeout!")
    end,
    post_case = function()
      vim.diagnostic.reset()
      vim.cmd("silent! %bwipeout!")
    end,
  },
})
T["providers"] = P

local function get(name, ctx)
  return require("duet.context").get(name, ctx)
end

P["file"] = function()
  local buf = fixture("src/main.lua", { "x" }, "lua")
  eq(get("file", ctx_for(buf)), { text = "src/main.lua", data = { path = "src/main.lua", filetype = "lua" } })
end

P["file: none for a buffer without a file"] = function()
  vim.cmd("enew!")
  eq(get("file", ctx_for(vim.api.nvim_get_current_buf())), nil)
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_name(0, vim.fs.joinpath(root, "scratch"))
  eq(get("file", ctx_for(vim.api.nvim_get_current_buf())), nil)
end

P["file: none for a scheme:// buffer"] = function()
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, "oil:///tmp/dir/")
  eq(get("file", ctx_for(vim.api.nvim_get_current_buf())), nil)
end

P["file: absolute outside the root"] = function()
  local other = h.tmp_dir()
  vim.cmd("enew!")
  vim.api.nvim_buf_set_name(0, vim.fs.joinpath(other, "x.txt"))
  eq(get("file", ctx_for(vim.api.nvim_get_current_buf())).text, vim.fs.joinpath(other, "x.txt"))
end

P["file: uses the adapter's format_ref"] = function()
  local buf = fixture("a.lua", { "x" }, "lua")
  local agent = assert(require("duet.agents").get("claude"))
  eq(get("file", ctx_for(buf, { agent = agent })).text, "@a.lua")
  eq(get("this", ctx_for(buf, { agent = agent, cursor = { 4, 0 } })).text, "@a.lua (line 4)")
end

P["file: falls back when format_ref fails"] = function()
  local buf = fixture("a.lua", { "x" }, "lua")
  local agent = {
    name = "broken",
    format_ref = function()
      error("nope")
    end,
  }
  eq(get("file", ctx_for(buf, { agent = agent })).text, "a.lua")
end

P["this"] = MiniTest.new_set({
  parametrize = {
    { "cursor line", { cursor = { 7, 3 } }, "a.lua:L7", 7, 7 },
    { "one-line range", { range = lines_range(4, 4) }, "a.lua:L4", 4, 4 },
    { "range", { range = lines_range(10, 20) }, "a.lua:L10-L20", 10, 20 },
  },
})

P["this"]["works"] = function(_, extra, text, s, e)
  local buf = fixture("a.lua", { "x" }, "lua")
  eq(get("this", ctx_for(buf, extra)), { text = text, data = { path = "a.lua", start_line = s, end_line = e } })
end

P["selection: lines"] = function()
  local buf = fixture("src/a.lua", { "local a = 1", "local b = 2", "local c = 3" }, "lua")
  local result = get("selection", ctx_for(buf, { range = lines_range(2, 3) }))
  eq(result.text, "src/a.lua:L2-L3\n```lua\nlocal b = 2\nlocal c = 3\n```")
  eq(result.block, true)
  eq(result.data, {
    path = "src/a.lua",
    filetype = "lua",
    start_line = 2,
    end_line = 3,
    mode = "line",
    text = "local b = 2\nlocal c = 3",
  })
end

P["selection: character-wise"] = function()
  local buf = fixture("a.lua", { "local abc = 1", "return abc" }, "lua")
  local range = { start_line = 1, end_line = 2, mode = "char", start_col = 7, end_col = 6 }
  local result = get("selection", ctx_for(buf, { range = range }))
  eq(result.text, "a.lua:L1-L2\n```lua\nabc = 1\nreturn\n```")
  eq({ result.data.start_col, result.data.end_col, result.data.mode }, { 7, 6, "char" })
end

P["selection: block-wise"] = function()
  local buf = fixture("a.txt", { "abcdef", "ghijkl" }, "text")
  local range = { start_line = 1, end_line = 2, mode = "block", start_col = 2, end_col = 3 }
  eq(get("selection", ctx_for(buf, { range = range })).data.text, "bc\nhi")
end

P["selection: multibyte character at the end"] = function()
  local buf = fixture("a.txt", { "aé b" }, "text")
  -- The end column is the first byte of "é", as getpos() gives it.
  local range = { start_line = 1, end_line = 1, mode = "char", start_col = 1, end_col = 2 }
  eq(get("selection", ctx_for(buf, { range = range })).data.text, "aé")
end

P["selection: a longer fence around backticks"] = function()
  local buf = fixture("README.md", { "```sh", "make", "```" }, "markdown")
  local result = get("selection", ctx_for(buf, { range = lines_range(1, 3) }))
  eq(result.text, "README.md:L1-L3\n````markdown\n```sh\nmake\n```\n````")
end

P["selection: no path line without a file"] = function()
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
  local result = get("selection", ctx_for(vim.api.nvim_get_current_buf(), { range = lines_range(1, 1) }))
  eq(result.text, "```\nx\n```")
  eq(result.data.path, nil)
end

P["selection: none without a range, or for blank lines"] = function()
  local buf = fixture("a.lua", { "x", "", "  " }, "lua")
  eq(get("selection", ctx_for(buf)), nil)
  eq(get("selection", ctx_for(buf, { range = lines_range(2, 3) })), nil)
end

local function diag(lnum, severity, message, extra)
  return vim.tbl_extend(
    "force",
    { lnum = lnum, col = 0, severity = severity, message = message, source = "test" },
    extra or {}
  )
end

P["diagnostics: sorted, errors first"] = function()
  local E, W, I = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN, vim.diagnostic.severity.INFO
  local buf = fixture("a.lua", { "1", "2", "3", "4", "5" }, "lua")
  vim.diagnostic.set(ns, buf, {
    diag(4, I, "info here"),
    diag(3, W, "unused x", { code = "unused-local" }),
    diag(0, E, "undefined y"),
    diag(1, E, "first line\nsecond line", { col = 2 }),
  })
  local result = get("diagnostics", ctx_for(buf))
  eq(
    result.text,
    table.concat({
      "a.lua:1: [ERROR] undefined y",
      "a.lua:2: [ERROR] first line",
      "  second line",
      "a.lua:4: [WARN] unused x",
      "a.lua:5: [INFO] info here",
    }, "\n")
  )
  eq(result.block, true)
  eq(result.data.items[2], {
    path = "a.lua",
    line = 2,
    col = 3,
    end_line = 2,
    severity = "ERROR",
    message = "first line\nsecond line",
    source = "test",
  })
  eq(result.data.items[3].code, "unused-local")
  eq(result.data.truncated, nil)
end

P["diagnostics: only those overlapping the range"] = function()
  local W = vim.diagnostic.severity.WARN
  local buf = fixture("a.lua", { "1", "2", "3", "4", "5", "6" }, "lua")
  vim.diagnostic.set(ns, buf, {
    diag(0, W, "before"),
    diag(1, W, "spans into the range", { end_lnum = 2 }),
    diag(3, W, "inside"),
    diag(5, W, "after"),
  })
  local result = get("diagnostics", ctx_for(buf, { range = lines_range(3, 4) }))
  eq(result.text, "a.lua:2: [WARN] spans into the range\na.lua:4: [WARN] inside")
end

P["diagnostics: none"] = function()
  local buf = fixture("a.lua", { "1", "2" }, "lua")
  eq(get("diagnostics", ctx_for(buf)), nil)
  vim.diagnostic.set(ns, buf, { diag(0, vim.diagnostic.severity.ERROR, "x") })
  eq(get("diagnostics", ctx_for(buf, { range = lines_range(2, 2) })), nil)
end

P["diagnostics: other buffers are left out"] = function()
  local other = fixture("b.lua", { "1" }, "lua")
  vim.diagnostic.set(ns, other, { diag(0, vim.diagnostic.severity.ERROR, "elsewhere") })
  local buf = fixture("a.lua", { "1" }, "lua")
  eq(get("diagnostics", ctx_for(buf)), nil)
end

P["diagnostics: at most MAX_ITEMS, errors kept"] = function()
  local buf = fixture("a.lua", vim.fn["repeat"]({ "x" }, 300), "lua")
  local list = {}
  for i = 0, 199 do
    list[#list + 1] = diag(i, vim.diagnostic.severity.HINT, "hint " .. i)
  end
  list[#list + 1] = diag(250, vim.diagnostic.severity.ERROR, "the error")
  vim.diagnostic.set(ns, buf, list)
  local result = get("diagnostics", ctx_for(buf))
  local lines = vim.split(result.text, "\n")
  eq(#lines, 201)
  eq(lines[1], "a.lua:251: [ERROR] the error")
  eq(lines[201], "… and 1 more")
  eq({ #result.data.items, result.data.truncated }, { 200, 1 })
end

P["diagnostics_all: every buffer, by severity then path"] = function()
  local E, W = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
  local b = fixture("b.lua", { "1", "2" }, "lua")
  vim.diagnostic.set(ns, b, { diag(1, W, "b warn"), diag(0, E, "b error") })
  local a = fixture("a.lua", { "1" }, "lua")
  vim.diagnostic.set(ns, a, { diag(0, W, "a warn") })
  eq(
    get("diagnostics_all", ctx_for(a)).text,
    "b.lua:1: [ERROR] b error\na.lua:1: [WARN] a warn\nb.lua:2: [WARN] b warn"
  )
end

P["diagnostics_all: none"] = function()
  eq(get("diagnostics_all", ctx_for(fixture("a.lua", { "1" }))), nil)
end

P["quickfix"] = function()
  local buf = fixture("a.lua", { "1", "2", "3" }, "lua")
  vim.fn.setqflist({}, " ", {
    title = "grep x",
    items = {
      { bufnr = buf, lnum = 2, col = 5, text = "  match one  ", type = "E" },
      { text = "a note line, not an entry", valid = 0 },
      { filename = vim.fs.joinpath(root, "b.lua"), lnum = 3, text = "match\ntwo" },
      { bufnr = buf, text = "file only" },
    },
  })
  -- setqflist marks the plain text item as invalid itself.
  local result = get("quickfix", ctx_for(buf))
  eq(result.text, "a.lua:2:5: match one\nb.lua:3: match\n  two\na.lua: file only")
  eq(result.data.title, "grep x")
  eq(result.data.items[1], { path = "a.lua", line = 2, col = 5, type = "E", text = "match one" })
  eq(result.block, true)
end

P["quickfix: none when empty"] = function()
  eq(get("quickfix", ctx_for(fixture("a.lua", { "1" }))), nil)
  vim.fn.setqflist({ { text = "only text" } }, "r")
  eq(get("quickfix", ctx_for(fixture("b.lua", { "1" }))), nil)
end

P["buffers"] = function()
  local a = fixture("a.lua", { "1" }, "lua")
  fixture("sub/b.lua", { "1" }, "lua")
  vim.bo.modified = true
  vim.cmd("enew!") -- no name: left out
  local unlisted = fixture("c.lua", { "1" }, "lua")
  vim.bo[unlisted].buflisted = false
  local result = get("buffers", ctx_for(a))
  eq(result.text, "a.lua\nsub/b.lua")
  eq(result.data, { items = { { path = "a.lua", modified = false }, { path = "sub/b.lua", modified = true } } })
end

P["buffers: none"] = function()
  vim.cmd("enew!")
  eq(get("buffers", ctx_for(vim.api.nvim_get_current_buf())), nil)
end

P["data encodes as JSON"] = function()
  local buf = fixture("a.lua", { "x = 1" }, "lua")
  vim.diagnostic.set(ns, buf, { diag(0, vim.diagnostic.severity.ERROR, "x") })
  vim.fn.setqflist({ { bufnr = buf, lnum = 1, text = "t" } }, "r")
  local ctx = ctx_for(buf, { range = lines_range(1, 1) })
  for _, name in ipairs(require("duet.context").names()) do
    local result = get(name, ctx)
    eq({ name, pcall(vim.json.encode, result.data) }, { name, true, vim.json.encode(result.data) })
  end
end

-- capture() in a child Neovim ---------------------------------------------------

local child = h.new_child()

local C = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.o.columns, child.o.lines = 160, 40
      local repo = h.tmp_git_repo({ ["src/a.lua"] = "local abc = 1\nlocal def = 2\nreturn abc\n" })
      child.lua(
        [[
        local repo = ...
        vim.cmd.cd(repo)
        vim.cmd.edit("src/a.lua")
        -- A probe subcommand: records what capture() sees for the command.
        require("duet.commands").register("probe", {
          impl = function(_, opts)
            _G.ctx = require("duet.context").capture(opts)
          end,
        })
        vim.keymap.set("x", "<F2>", "<Cmd>Duet probe<CR>")
        vim.keymap.set("x", "<F3>", function()
          _G.ctx = require("duet.context").capture()
        end)
        _G.code_win = vim.api.nvim_get_current_win()
        _G.code_buf = vim.api.nvim_get_current_buf()
      ]],
        { repo }
      )
      child.lua("_G.repo = ...", { repo })
    end,
    post_once = child.stop,
  },
})
T["capture()"] = C

local function ctx()
  return child.lua_get([[{
    range = _G.ctx.range or vim.NIL,
    cursor = _G.ctx.cursor,
    same_win = _G.ctx.win == _G.code_win,
    same_buf = _G.ctx.buf == _G.code_buf,
    cwd_is_repo = _G.ctx.cwd == _G.repo,
    agent = _G.ctx.agent and _G.ctx.agent.name or vim.NIL,
  }]])
end

C["without a range"] = function()
  child.api.nvim_win_set_cursor(0, { 2, 4 })
  child.cmd("Duet probe")
  eq(
    ctx(),
    { range = vim.NIL, cursor = { 2, 4 }, same_win = true, same_buf = true, cwd_is_repo = true, agent = "claude" }
  )
end

C["with a line range"] = function()
  child.cmd("2,3Duet probe")
  eq(ctx().range, { start_line = 2, end_line = 3, mode = "line" })
end

C["line-wise visual selection"] = function()
  child.type_keys("V", "j", ":", "Duet probe<CR>")
  eq(ctx().range, { start_line = 1, end_line = 2, mode = "line" })
end

C["an Ex range from a character-wise selection is whole lines"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 6 })
  child.type_keys("v", "j", "0", "e", ":", "Duet probe<CR>")
  eq(ctx().range, { start_line = 1, end_line = 2, mode = "line" })
end

C["an old character-wise selection doesn't change a typed range"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 6 })
  child.type_keys("v", "j", "<Esc>")
  child.cmd("1,2Duet probe")
  eq(ctx().range, { start_line = 1, end_line = 2, mode = "line" })
end

C["character-wise selection from a <Cmd> mapping keeps its columns"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 6 })
  child.type_keys("v", "j", "0", "e", "<F2>")
  eq(ctx().range, { start_line = 1, end_line = 2, mode = "char", start_col = 7, end_col = 5 })
end

C["v$ ends on the last character"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 2 })
  child.type_keys("v", "$", "<F2>")
  -- "local abc = 1" is 13 bytes.
  eq(ctx().range, { start_line = 1, end_line = 1, mode = "char", start_col = 3, end_col = 13 })
end

C["block-wise selection from a <Cmd> mapping keeps each corner's column"] = function()
  child.api.nvim_win_set_cursor(0, { 1, 8 })
  child.type_keys("<C-v>", "j", "h", "h", "<F2>")
  eq(ctx().range, { start_line = 1, end_line = 2, mode = "block", start_col = 9, end_col = 7 })
end

C["block-wise selection over a tab gives what Vim yanks"] = function()
  child.lua([[
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefghij", "\tXYZ" })
    vim.bo.expandtab, vim.bo.tabstop = false, 8
  ]])
  child.api.nvim_win_set_cursor(0, { 1, 4 })
  -- From "e" (screen column 5) down onto the tab on line 2 (screen columns 1-8).
  child.type_keys("<C-v>", "j", "<F2>", '"zy')
  local want = child.lua_get("vim.split(vim.fn.getreg('z'), '\\n')")
  eq(child.lua_get("require('duet.context').get('selection', _G.ctx).data.text"), table.concat(want, "\n"))
end

---Select a block from {line, col} (0-based col) with `keys`, capture it with <F2>, then
---yank the same block with Vim; return duet's text and Vim's.
local function block_vs_yank(lines, cursor, keys)
  child.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, ...)", { lines })
  child.api.nvim_win_set_cursor(0, cursor)
  child.type_keys("<C-v>", keys, "<F2>", '"zy')
  return child.lua_get("require('duet.context').get('selection', _G.ctx).data.text"), child.fn.getreg("z")
end

C["a block made with $ takes each line to its end"] = function()
  local got, want = block_vs_yank({ "abcdefgh", "ab", "abc" }, { 1, 1 }, "2j$")
  eq(got, "bcdefgh\nb\nbc")
  eq(got, want)
  eq(ctx().range.to_end, true)
end

C["a $ block over a line shorter than its left column"] = function()
  local got, want = block_vs_yank({ "abcdefgh", "a", "abcdef" }, { 1, 2 }, "2j$")
  -- A yank pads the short line with spaces; the agent gets it empty.
  eq(got, "cdefgh\n\ncdef")
  eq(want, "cdefgh\n" .. string.rep(" ", 7) .. "\ncdef")
end

C["a block without $ is not to_end"] = function()
  block_vs_yank({ "abcdefgh", "ab", "abc" }, { 1, 1 }, "2jl")
  eq(ctx().range.to_end, nil)
end

C["a selection in Select mode"] = function()
  child.lua([[
    vim.keymap.set("s", "<F6>", function()
      _G.ctx = require("duet.context").capture()
      require("duet.context").leave_visual()
    end)
  ]])
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys("gh", "<Right>", "<F6>")
  eq(ctx().range, { start_line = 1, end_line = 1, mode = "char", start_col = 1, end_col = 2 })
  eq(child.fn.mode(), "n")
end

C["selection made backwards, from Lua"] = function()
  child.api.nvim_win_set_cursor(0, { 2, 2 })
  child.type_keys("v", "k", "<F3>")
  eq(ctx().range, { start_line = 1, end_line = 2, mode = "char", start_col = 3, end_col = 3 })
end

C["from a terminal, takes the code window and drops the range"] = function()
  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.cmd("vsplit | terminal")
  child.cmd("1,1Duet probe")
  local got = ctx()
  eq({ got.same_win, got.same_buf, got.range, got.cursor }, { true, true, vim.NIL, { 3, 0 } })
end

C["from a terminal, finds a code window that is not the previous one"] = function()
  child.cmd("vsplit | terminal")
  child.cmd("split | help help")
  child.cmd("wincmd j")
  -- The previous window is the help window: not code.
  child.cmd("Duet probe")
  eq(ctx().same_win, true)
end

C["uses the agent asked for"] = function()
  child.lua([[
    require("duet.agents").register({
      name = "other",
      cmd = { "true" },
      capabilities = { mcp = false, plan_hook = false, system_prompt = false },
      launch = function() return { argv = { "true" }, env = {}, files = {} } end,
    })
    _G.ctx = require("duet.context").capture({ agent = "other" })
  ]])
  eq(ctx().agent, "other")
end

return T
