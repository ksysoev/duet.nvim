local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

-- parse() ----------------------------------------------------------------------

---@param path string
---@param s integer
---@param e integer
---@param extra? table line, end_line, col
local function link(path, s, e, extra)
  return vim.tbl_extend("force", { path = path, s = s, e = e }, extra or {})
end

-- Lines as Claude Code and the tools it runs print them.
T["parse()"] = MiniTest.new_set({
  parametrize = {
    { "path:line", "see lua/duet/init.lua:10 now", { link("lua/duet/init.lua", 5, 24, { line = 10 }) } },
    { "path:line:col", "lua/duet/init.lua:10:5", { link("lua/duet/init.lua", 1, 22, { line = 10, col = 5 }) } },
    { "path:line-line", "init.lua:10-20", { link("init.lua", 1, 14, { line = 10, end_line = 20 }) } },
    { "path:Lline-Lline", "a.lua:L10-L20", { link("a.lua", 1, 13, { line = 10, end_line = 20 }) } },
    { "path:Lline", "a.lua:L7", { link("a.lua", 1, 8, { line = 7 }) } },
    { "path#Lline", "a.lua#L10", { link("a.lua", 1, 9, { line = 10 }) } },
    { "path#Lline-Lline", "a.lua#L10-L20", { link("a.lua", 1, 13, { line = 10, end_line = 20 }) } },
    { "path#Lline-line", "a.lua#L10-20", { link("a.lua", 1, 12, { line = 10, end_line = 20 }) } },
    { "path#LlineCcol", "a.lua#L10C5", { link("a.lua", 1, 11, { line = 10, col = 5 }) } },
    { "@path", "look at @lua/duet/init.lua", { link("lua/duet/init.lua", 9, 26) } },
    {
      "@path (lines a-b), as duet sends it",
      "@lua/duet/init.lua (lines 10-20)",
      { link("lua/duet/init.lua", 1, 32, { line = 10, end_line = 20 }) },
    },
    { "@path (line n)", "@lua/x.lua (line 4) next", { link("lua/x.lua", 1, 19, { line = 4 }) } },
    { "in backticks", "use `lua/duet/init.lua:42` here", { link("lua/duet/init.lua", 6, 25, { line = 42 }) } },
    { "bare name in backticks", "edit `Makefile` first", { link("Makefile", 7, 14) } },
    { "bare name with a line", "Makefile:12", { link("Makefile", 1, 11, { line = 12 }) } },
    { "tool call header", "⏺ Read(lua/duet/init.lua)", { link("lua/duet/init.lua", 10, 26) } },
    { "tool result", "  ⎿  Wrote 120 lines to tests/test_links.lua", { link("tests/test_links.lua", 27, 46) } },
    { "box drawing around", "│ a.lua:3 │", { link("a.lua", 5, 11, { line = 3 }) } },
    {
      "two links on a line",
      "a.lua:3 and b/c.lua:4",
      { link("a.lua", 1, 7, { line = 3 }), link("b/c.lua", 13, 21, { line = 4 }) },
    },
    { "go compiler error", "./foo.go:12:3: undefined: x", { link("./foo.go", 1, 13, { line = 12, col = 3 }) } },
    { "lua error", "lua/duet/x.lua:10: attempt to index nil", { link("lua/duet/x.lua", 1, 17, { line = 10 }) } },
    { "rust error", "  --> src/main.rs:10:5", { link("src/main.rs", 7, 22, { line = 10, col = 5 }) } },
    { "js stack frame", "    at f (/abs/a.js:10:5)", { link("/abs/a.js", 11, 24, { line = 10, col = 5 }) } },
    { "python traceback", '  File "x.py", line 10, in f', { link("x.py", 9, 22, { line = 10 }) } },
    { "absolute path", "/Users/me/p/a.lua:3", { link("/Users/me/p/a.lua", 1, 19, { line = 3 }) } },
    { "home path", "~/notes.md", { link("~/notes.md", 1, 10) } },
    { "parent path", "../a.lua:3", { link("../a.lua", 1, 10, { line = 3 }) } },
    { "diff stat", " lua/duet/links.lua | 30 +++", { link("lua/duet/links.lua", 2, 19) } },
    { "markdown bold", "**lua/a.lua**", { link("lua/a.lua", 3, 11) } },
    { "@ before markdown bold", "@**a.lua**", { link("a.lua", 1, 8) } },
    { "@ inside markdown bold", "**@a.lua**", { link("a.lua", 3, 8) } },
    { "markdown link", "[x](lua/a.lua#L3)", { link("lua/a.lua", 5, 16, { line = 3 }) } },
    { "trailing punctuation", "(see a.lua:3).", { link("a.lua", 6, 12, { line = 3 }) } },
    { "trailing comma and colon", "a.lua:3, b.lua:", { link("a.lua", 1, 7, { line = 3 }), link("b.lua", 10, 14) } },
    { "leading underscores", "__init__.py", { link("__init__.py", 1, 11) } },
    { "file URI", "file:///abs/a%20b.lua#L3", { link("/abs/a b.lua", 1, 24, { line = 3 }) } },
    { "reversed range", "a.lua:20-10", { link("a.lua", 1, 11, { line = 10, end_line = 20 }) } },
    { "multibyte before", "é → a.lua:3", { link("a.lua", 8, 14, { line = 3 }) } },
    { "https URL", "https://github.com/x/y/blob/main/a.lua#L10", {} },
    { "time and plain words", "at 10:30 and/or not", { link("and/or", 10, 15) } },
    { "number", "42", {} },
    { "empty", "", {} },
    { "rg -n match", "lua/duet/init.lua:12:local M = {}", { link("lua/duet/init.lua", 1, 20, { line = 12 }) } },
    { "rg --column match", "a.lua:12:5:local x", { link("a.lua", 1, 10, { line = 12, col = 5 }) } },
    { "grep match with a URL", "a.lua:3:see http://x", { link("a.lua", 1, 7, { line = 3 }) } },
    { "a clock time", "10:30:00", {} },
    { "URL with a port", "http://host:8080/x", {} },
    { "reversed phrase range", "@a.lua (lines 20-10)", { link("a.lua", 1, 20, { line = 10, end_line = 20 }) } },
    { "file URI with an encoded #", "file:///r/a%23L2", { link("/r/a#L2", 1, 16) } },
    { "file URI with an encoded # and a line", "file:///r/a%23b.lua#L3", { link("/r/a#b.lua", 1, 22, { line = 3 }) } },
  },
})

T["parse()"]["finds %s"] = function(_, line, want)
  eq(require("duet.links").parse(line), want)
end

-- Files that exist, for parse()'s `exists` and find()'s `resolve`.
local FILES = {
  ["a.lua"] = true,
  ["lua/a.lua"] = true,
  ["my-file.lua"] = true,
  ["my-file-12-notes.md"] = true,
  ["2024-01-05-notes.md"] = true,
  ["Makefile"] = true,
  ["lua/duet/some/long/path.lua"] = true,
}

-- Directories that exist.
local DIRS = { ["docs/adr"] = true }

local function exists(path)
  return FILES[path] == true
end

T["parse() with exists"] = MiniTest.new_set({
  parametrize = {
    { "rg -C context line", "lua/a.lua-12-local M = {}", { link("lua/a.lua", 1, 12, { line = 12 }) } },
    { "empty context line", "a.lua-7-", { link("a.lua", 1, 7, { line = 7 }) } },
    { "hyphenated name in a context line", "my-file.lua-3-x", { link("my-file.lua", 1, 13, { line = 3 }) } },
    { "dated name in a context line", "2024-01-05-notes.md-3-x", { link("2024-01-05-notes.md", 1, 21, { line = 3 }) } },
    { "hyphenated name that exists", "see my-file-12-notes.md", { link("my-file-12-notes.md", 5, 23) } },
    { "hyphenated name that does not", "see my-file-12-notes.md.bak", { link("my-file-12-notes.md.bak", 5, 27) } },
    { "hyphen form of a missing file", "docs/x-1-y.md", { link("docs/x-1-y.md", 1, 13) } },
    -- Without an extension or a `/`, the part before the number is too likely a word.
    { "bare name in a context line", "Makefile-3-all:", {} },
    { "bare name in backticks", "`Makefile-3-all`", { link("Makefile-3-all", 2, 15) } },
    { "match lines come first", "a.lua:3:x-1-y", { link("a.lua", 1, 7, { line = 3 }) } },
    { "context line with colons in its text", "a.lua-4-x:5:y", { link("a.lua", 1, 7, { line = 4 }) } },
  },
})

T["parse() with exists"]["finds %s"] = function(_, line, want)
  eq(require("duet.links").parse(line, { exists = exists }), want)
end

T["parse() without exists"] = function()
  -- Nothing to check the path against: the whole token is the name.
  eq(require("duet.links").parse("lua/a.lua-12-local"), { link("lua/a.lua-12-local", 1, 18) })
end

-- find() -------------------------------------------------------------------------

---@param path string
---@param row integer
---@param s integer
---@param e integer
---@param extra? table line, end_line, col, tail
local function found(path, row, s, e, extra)
  return vim.tbl_extend("force", link(path, s, e, extra), { row = row, abs = "/r/" .. path })
end

local LONG = "lua/duet/some/long/path.lua"

T["find()"] = MiniTest.new_set({
  parametrize = {
    {
      "a reference wrapped by the terminal",
      { "xxxx lua/duet/so", "me/long/path.lua:120 after" },
      16,
      { found(LONG, 1, 6, 16, { line = 120, tail = { row = 2, s = 1, e = 20 } }) },
    },
    {
      "a reference wrapped and indented by a TUI",
      { "⏺ x lua/duet/some/long", "  /path.lua:12 y" },
      22,
      { found(LONG, 1, 7, 24, { line = 12, tail = { row = 2, s = 3, e = 14 } }) },
    },
    {
      "a line number split by the wrap",
      { "see lua/a.lua:1", "20 now" },
      15,
      { found("lua/a.lua", 1, 5, 15, { line = 120, tail = { row = 2, s = 1, e = 2 } }) },
    },
    {
      "a row a cell short of the width",
      { "xxxx lua/duet/so", "  me/long/path.lua" },
      17,
      { found(LONG, 1, 6, 16, { tail = { row = 2, s = 3, e = 18 } }) },
    },
    {
      "a row that is not full",
      { "xxxx lua/duet/so", "me/long/path.lua:120" },
      30,
      {},
    },
    {
      "halves that do not join into a file",
      { "aaaa a.lua:3", "a.lua" },
      12,
      { found("a.lua", 1, 6, 12, { line = 3 }), found("a.lua", 2, 1, 5) },
    },
    { "no width", { "xxxx lua/duet/so", "me/long/path.lua:120" }, false, {} },
    {
      "a row wider than the terminal, from before it was narrowed",
      { "xxxx lua/duet/so", "me/long/path.lua:120" },
      12,
      {},
    },
    {
      "a terminal wrap at a space after a reference",
      { "see lua/a.lua:1", " 2 tests" },
      15,
      { found("lua/a.lua", 1, 5, 15, { line = 1 }) },
    },
    {
      "a TUI wrap at a space after a reference",
      { "  see lua/a.lua:1", "  2 tests" },
      17,
      { found("lua/a.lua", 1, 7, 17, { line = 1 }) },
    },
    {
      "a row a cell short that ends with a link",
      { "see lua/a.lua:1", "2. next" },
      16,
      { found("lua/a.lua", 1, 5, 15, { line = 1 }) },
    },
    {
      "a terminal wrap in a row a cell short",
      { "xxxx lua/duet/so", "me/long/path.lua" },
      18,
      {},
    },
    { "a context line naming a directory", { "docs/adr-0001-use-x.md" }, false, {} },
    {
      "a space the terminal wrapped onto the next row",
      { LONG .. ":1", " 2 tests" },
      29,
      { found(LONG, 1, 1, 29, { line = 1 }) },
    },
    {
      "a TUI's rows padded with spaces",
      { "  x lua/duet/some/lon ", "  g/path.lua:3 y      " },
      22,
      { found(LONG, 1, 5, 21, { line = 3, tail = { row = 2, s = 3, e = 14 } }) },
    },
    {
      "a reference over three rows",
      { "aaaa lua/duet/so", "me/long/path.lua", ":5 b" },
      16,
      {},
    },
    {
      "a wrapped context line",
      { "lua/duet/some/long/pa", "th.lua-9-text" },
      21,
      { found(LONG, 1, 1, 21, { line = 9, tail = { row = 2, s = 1, e = 8 } }) },
    },
    {
      "links on the rows around a wrapped one",
      { "a.lua:1 lua/duet/some", "/long/path.lua:2 a.lua:3" },
      21,
      {
        found("a.lua", 1, 1, 7, { line = 1 }),
        found(LONG, 1, 9, 21, { line = 2, tail = { row = 2, s = 1, e = 16 } }),
        found("a.lua", 2, 18, 24, { line = 3 }),
      },
    },
  },
})

T["find()"]["finds %s"] = function(_, lines, width, want)
  local got = require("duet.links").find(lines, {
    width = width or nil,
    resolve = function(path)
      return (exists(path) or DIRS[path]) and ("/r/" .. path) or nil
    end,
    is_file = function(abs)
      return exists(abs:sub(4))
    end,
  })
  eq(got, want)
end

T["find()"]["starts at the given row"] = function()
  local got = require("duet.links").find({ "a.lua:2" }, {
    first = 7,
    resolve = function(path)
      return "/r/" .. path
    end,
  })
  eq(got, { found("a.lua", 7, 1, 7, { line = 2 }) })
end

-- parse_ref() --------------------------------------------------------------------

T["parse_ref()"] = MiniTest.new_set({
  parametrize = {
    { "a path", "a.lua:3", false, { path = "a.lua", line = 3 } },
    { "a relative OSC 8 target", "lua/a.lua#L5", false, { path = "lua/a.lua", line = 5 } },
    { "a bare name when marked", "README", true, { path = "README" } },
    { "a bare name unmarked", "README", false, nil },
    { "a URL", "https://example.com/a.lua", true, nil },
    { "a file URI with a host", "file://localhost/a.lua", false, { path = "/a.lua" } },
  },
})

T["parse_ref()"]["parses %s"] = function(_, token, marked, want)
  eq(require("duet.links").parse_ref(token, marked), want)
end

-- cell_to_byte() -----------------------------------------------------------------

T["cell_to_byte()"] = MiniTest.new_set({
  parametrize = {
    { "ASCII", "ab cd", 3, 3 },
    { "cell 0", "⏺ x", 0, 0 },
    { "after a one-cell symbol", "⏺ link", 2, 4 },
    { "after wide characters", "漢字 link", 5, 7 },
    { "past the end", "ab", 10, 2 },
    { "empty line", "", 4, 0 },
  },
})

T["cell_to_byte()"]["converts %s"] = function(_, text, cell, want)
  eq(require("duet.links").cell_to_byte(text, cell), want)
end

-- resolve() ----------------------------------------------------------------------

T["click_keys()"] = MiniTest.new_set({
  parametrize = {
    { "<C-LeftMouse>", { drag = "<C-LeftDrag>", release = "<C-LeftRelease>", button = "Left", count = "" } },
    { "<c-leftmouse>", { drag = "<C-LeftDrag>", release = "<C-LeftRelease>", button = "Left", count = "" } },
    { "<C-M-LeftMouse>", { drag = "<C-M-LeftDrag>", release = "<C-M-LeftRelease>", button = "Left", count = "" } },
    { "<A-RightMouse>", { drag = "<M-RightDrag>", release = "<M-RightRelease>", button = "Right", count = "" } },
    -- A double click's drag and release carry its count.
    { "<2-C-LeftMouse>", { drag = "<2-C-LeftDrag>", release = "<2-C-LeftRelease>", button = "Left", count = "2-" } },
    { "<MiddleMouse>", { drag = "<MiddleDrag>", release = "<MiddleRelease>", button = "Middle", count = "" } },
    { "gf", nil },
    { "<C-LeftRelease>", nil },
  },
})

T["click_keys()"]["for %s"] = function(lhs, want)
  -- Compared as keys: `<M-C-LeftDrag>` is `<C-M-LeftDrag>`.
  local function codes(keys)
    return keys
      and {
        drag = vim.keycode(keys.drag),
        release = vim.keycode(keys.release),
        button = keys.button,
        count = keys.count,
      }
  end
  eq(codes(require("duet.links").click_keys(lhs)), codes(want))
end

T["resolve()"] = MiniTest.new_set()

local function repo()
  return h.tmp_git_repo({ ["lua/a.lua"] = "a\n", ["top.lua"] = "top\n", ["dir/x.txt"] = "x\n" })
end

T["resolve()"]["finds a path relative to cwd"] = function()
  local root = repo()
  eq(require("duet.links").resolve("lua/a.lua", root), root .. "/lua/a.lua")
end

T["resolve()"]["falls back to the git root"] = function()
  local root = repo()
  eq(require("duet.links").resolve("top.lua", root .. "/lua"), root .. "/top.lua")
end

T["resolve()"]["prefers cwd over the git root"] = function()
  local root = h.tmp_git_repo({ ["a.lua"] = "root\n", ["sub/a.lua"] = "sub\n" })
  eq(require("duet.links").resolve("a.lua", root .. "/sub"), root .. "/sub/a.lua")
end

T["resolve()"]["takes absolute paths as they are"] = function()
  local root = repo()
  eq(require("duet.links").resolve(root .. "/top.lua", "/"), root .. "/top.lua")
end

T["resolve()"]["normalizes ./ and .."] = function()
  local root = repo()
  eq(require("duet.links").resolve("./lua/../top.lua", root), root .. "/top.lua")
end

T["resolve()"]["expands ~"] = function()
  local home = h.tmp_dir()
  vim.fn.writefile({ "x" }, home .. "/notes.md")
  local saved = vim.env.HOME
  vim.env.HOME = home
  local abs = require("duet.links").resolve("~/notes.md", "/")
  vim.env.HOME = saved
  eq(abs, home .. "/notes.md")
end

T["resolve()"]["finds directories"] = function()
  local root = repo()
  eq(require("duet.links").resolve("dir", root), root .. "/dir")
end

T["resolve()"]["resolver() resolves many paths from one cwd"] = function()
  local root = repo()
  local resolve = require("duet.links").resolver(root .. "/lua")
  eq({ resolve("a.lua"), resolve("top.lua"), (resolve("nope.lua")) }, { root .. "/lua/a.lua", root .. "/top.lua" })
end

T["resolve()"]["reports a missing file"] = function()
  local root = repo()
  local abs, err = require("duet.links").resolve("nope.lua", root)
  eq(abs, nil)
  eq(err, "links: no such file 'nope.lua'")
end

-- In a terminal ------------------------------------------------------------------

local child = h.new_child()
local root

-- A child in a temporary repo, with a notify recorder and a fake agent that prints `out`.
local function start()
  root = h.tmp_git_repo({
    ["lua/duet/init.lua"] = table.concat(
      vim.tbl_map(function(n)
        return "line " .. n
      end, vim.fn.range(1, 40)),
      "\n"
    ) .. "\n",
    ["a.lua"] = "a\n",
    ["b.lua"] = "b\n",
    ["c.lua"] = "c\n",
  })
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.o.columns, child.o.lines = 200, 50
  child.fn.chdir(root)
  child.lua([[
    _G.notes = {}
    vim.notify = function(msg, level)
      table.insert(_G.notes, { msg = msg, level = level })
    end
    _G.T = require("duet.terminal")
    _G.L = require("duet.links")
    _G.wait = function(fn, ms)
      return vim.wait(ms or 3000, fn, 10)
    end
    _G.agent = function(script, opts)
      require("duet.agents").register({
        name = "fake",
        cmd = { "sh", "-c", script .. "; cat" },
        capabilities = { mcp = false, plan_hook = false, system_prompt = false },
        launch = function(self)
          return { argv = vim.deepcopy(self.cmd), env = {}, files = {} }
        end,
      })
      local base = { agent = "fake", terminal = { auto_insert = false } }
      require("duet").setup(vim.tbl_deep_extend("force", base, opts or {}))
      _G.s = assert(T.open())
    end
    -- Wait for `needle` in the terminal and put the cursor on it.
    _G.cursor_on = function(needle)
      local row, col
      wait(function()
        for i, line in ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
          col = line:find(needle, 1, true)
          if col then
            row = i
            return true
          end
        end
      end)
      assert(row, "not in the terminal: " .. needle)
      vim.api.nvim_set_current_win(s:window())
      vim.api.nvim_win_set_cursor(0, { row, col - 1 })
      return row
    end
    _G.where = function()
      return {
        name = vim.api.nvim_buf_get_name(0),
        line = vim.fn.line("."),
        col = vim.fn.col("."),
        terminal = vim.bo.buftype == "terminal",
      }
    end
  ]])
end

local function agent(script, opts)
  child.lua("_G.agent(...)", { script, opts or {} })
end

local function rel(name)
  return name:sub(#root + 2)
end

T["terminal"] = MiniTest.new_set({ hooks = { pre_case = start, post_once = child.stop } })

T["terminal"]["gf opens the file at the line in the other window"] = function()
  agent("printf 'see lua/duet/init.lua:10 now\\n'")
  local code = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  child.lua("cursor_on('init.lua')")
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq(rel(at.name), "lua/duet/init.lua")
  eq({ at.line, at.terminal }, { 10, false })
  eq(child.lua_get("vim.api.nvim_get_current_win()"), code)
  eq(child.lua_get("s:is_visible()"), true)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  eq(child.lua_get("_G.notes"), {})
end

T["terminal"]["<CR> opens with the column"] = function()
  agent("printf 'lua/duet/init.lua:12:3\\n'")
  child.lua("cursor_on('lua/duet')")
  child.type_keys("<CR>")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line, at.col }, { "lua/duet/init.lua", 12, 3 })
end

T["terminal"]["gf opens a grep context line at its line"] = function()
  child.fn.writefile({ "x" }, root .. "/my-file-12-notes.md")
  -- As `rg -C1 'line 12'` prints it, with a hyphenated name below.
  agent(
    "printf 'lua/duet/init.lua-11-line 11\\nlua/duet/init.lua:12:line 12\\nlua/duet/init.lua-13-line 13\\n"
      .. "see my-file-12-notes.md\\n'"
  )
  child.lua("cursor_on('init.lua-13')")
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 13 })
  -- On the text after the line number, <CR> moves down as it does on plain text.
  child.lua("vim.cmd.wincmd('p'); cursor_on('1-line 11')")
  child.type_keys("2l", "<CR>")
  eq(child.lua_get("{ where().terminal, _G.notes }"), { true, {} })
  child.lua("cursor_on('my-file')")
  child.type_keys("gf")
  eq(rel(child.lua_get("where().name")), "my-file-12-notes.md")
end

-- Pads the line so that the reference starts 10 cells before the terminal's right edge.
local WRAP = "sleep 0.2; w=$(stty size | cut -d' ' -f2); pad=$(printf '%%*s' $((w - 11)) '' | tr ' ' x); "
  .. "printf '%%s %s after\\n' \"$pad\""

T["terminal"]["gf works on either half of a wrapped reference"] = MiniTest.new_set({
  parametrize = { { "head", "x lua" }, { "tail", "nit.lua:2" } },
})

T["terminal"]["gf works on either half of a wrapped reference"]["the %s"] = function(_, needle)
  agent(WRAP:format("lua/duet/init.lua:25"))
  child.lua("cursor_on('after')")
  child.lua("cursor_on(...)", { needle })
  if needle == "x lua" then
    child.type_keys("2l") -- onto "lua"
  end
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 25 })
end

T["terminal"]["[l stays in the window on a wrapped reference"] = function()
  agent(WRAP:format("lua/duet/init.lua:25"))
  local row = child.lua_get("cursor_on('after')")
  -- Only the tail is in the window; the cursor is after it.
  child.lua("vim.fn.winrestview({ topline = ... }); vim.cmd('normal! $')", { row })
  child.type_keys("[l")
  eq(child.lua_get("{ vim.api.nvim_win_get_cursor(0), vim.fn.line('w0') }"), { { row, 0 }, row })
end

T["terminal"]["highlights both halves of a wrapped reference"] = function()
  agent(WRAP:format("lua/duet/init.lua:25"), { links = { highlight = true, debounce_ms = 10 } })
  local row = child.lua_get("cursor_on('after')")
  local rows = child.lua_get([[(function()
    local ns = vim.api.nvim_create_namespace("duet.links")
    wait(function() return #vim.api.nvim_buf_get_extmarks(s.buf, ns, 0, -1, {}) == 2 end)
    return vim.tbl_map(function(m) return m[2] + 1 end, vim.api.nvim_buf_get_extmarks(s.buf, ns, 0, -1, {}))
  end)()]])
  eq(rows, { row - 1, row })
end

T["terminal"]["a missing file shows a notification"] = function()
  agent("printf 'see missing/nope.lua:3\\n'")
  child.lua("cursor_on('nope')")
  child.type_keys("gf")
  eq(child.lua_get("where().terminal"), true)
  eq(child.lua_get("_G.notes"), { { msg = "[duet] links: no such file 'missing/nope.lua'", level = 3 } })
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["terminal"]["no link under the cursor shows a notification"] = function()
  agent("printf 'nothing here\\n'")
  child.lua("cursor_on('nothing')")
  child.type_keys("gf")
  eq(child.lua_get("_G.notes"), { { msg = "[duet] links: no file link under the cursor", level = 3 } })
end

T["terminal"]["<CR> moves down where there is no link"] = function()
  agent("printf 'nothing here\\nnext line\\n'")
  local row = child.lua_get("cursor_on('nothing')")
  child.type_keys("<CR>")
  eq(child.lua_get("{ vim.fn.line('.'), where().terminal }"), { row + 1, true })
  eq(child.lua_get("_G.notes"), {})
end

T["terminal"]["<CR> on a missing file shows a notification"] = function()
  agent("printf 'see missing/nope.lua:3\\n'")
  child.lua("cursor_on('nope')")
  child.type_keys("<CR>")
  eq(child.lua_get("_G.notes"), { { msg = "[duet] links: no such file 'missing/nope.lua'", level = 3 } })
end

T["terminal"]["a floating terminal is hidden"] = function()
  agent("printf 'a.lua:1\\n'", { terminal = { layout = "float" } })
  child.lua("cursor_on('a.lua')")
  child.type_keys("gf")
  eq(rel(child.lua_get("where().name")), "a.lua")
  eq(child.lua_get("s:is_visible()"), false)
end

T["terminal"]["opens a split when there is no code window"] = function()
  agent("printf 'a.lua:1\\n'")
  child.lua("cursor_on('a.lua'); vim.cmd('only')")
  child.type_keys("gf")
  eq(rel(child.lua_get("where().name")), "a.lua")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  eq(child.lua_get("s:is_visible()"), true)
  -- The terminal is on the right, so the file goes on the left.
  eq(child.lua_get("vim.fn.winnr()"), 1)
  -- With nothing else to take room from, the terminal's window is split in two.
  eq(child.lua_get("vim.api.nvim_win_get_width(0) >= 90"), true)
end

T["terminal"]["a split for the file keeps the terminal's size"] = function()
  -- A sidebar is the only other window: it is not a code window. The terminal's split
  -- fixes its width, so the new window takes its room from the sidebar.
  child.lua("vim.bo.buftype = 'nofile'")
  agent("printf 'a.lua:1\\n'")
  child.lua("cursor_on('a.lua')")
  local before = child.lua_get("vim.api.nvim_win_get_width(s:window())")
  child.type_keys("gf")
  child.lua("vim.wait(50)") -- let WinResized run
  eq(rel(child.lua_get("where().name")), "a.lua")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
  eq(child.lua_get("vim.api.nvim_win_get_width(s:window())"), before)
  -- The split's size was duet's, not taken as one the user made by hand.
  eq(child.lua_get("vim.w[s:window()].duet_hand"), vim.NIL)
  eq(child.lua_get("vim.api.nvim_win_get_width(0) >= 20"), true)
end

---Show a new scratch buffer like a start screen or sidebar draws (`buftype=nofile`) with
---`filetype` in the current window, or in a new split with `split`. Returns the window.
---@param filetype string
---@param split? string e.g. "topleft vertical 30 new"
---@return integer
local function screen(filetype, split)
  return child.lua_get(
    [[(function(filetype, split)
      if split then vim.cmd(split) end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(0, buf)
      -- Drawn, as start screens are: `:edit` would reuse an empty, unnamed buffer.
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { filetype })
      vim.bo[buf].filetype = filetype
      return vim.api.nvim_get_current_win()
    end)(...)]],
    { filetype, split }
  )
end

---Open the link on the terminal's `a.lua:1` line from the terminal, with `prev` as the
---previous window when given.
---@param prev? integer
local function follow_from(prev)
  if prev then
    child.lua("vim.api.nvim_set_current_win(...)", { prev })
  end
  child.lua("cursor_on('a.lua')")
  child.type_keys("gf")
  eq(rel(child.lua_get("where().name")), "a.lua")
end

---Show `file` in the current window, with 'winfixbuf' set when `pinned`. Returns the
---window.
---@param file string
---@param pinned? boolean
---@return integer
local function show_code(file, pinned)
  child.cmd("edit " .. file)
  child.wo.winfixbuf = pinned == true
  return child.lua_get("vim.api.nvim_get_current_win()")
end

T["terminal"]["a code window that sets 'winfixbuf'"] = MiniTest.new_set()

T["terminal"]["a code window that sets 'winfixbuf'"]["is skipped for a split"] = function()
  local pinned = show_code("b.lua", true)
  agent("printf 'a.lua:1\\n'")
  child.lua("cursor_on('a.lua')")
  child.type_keys("gf")
  eq(child.lua_get("_G.notes"), {})
  eq(rel(child.lua_get("where().name")), "a.lua")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
  eq(child.lua_get("vim.api.nvim_get_current_win() ~= ...", { pinned }), true)
  eq(rel(child.lua_get("vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(...))", { pinned })), "b.lua")
  -- The split does not take the pinned window's 'winfixbuf'.
  eq(child.lua_get("vim.wo.winfixbuf"), false)
end

T["terminal"]["a code window that sets 'winfixbuf'"]["is skipped for a start screen"] = function()
  local pinned = show_code("b.lua", true)
  local dashboard = screen("alpha", "botright new")
  agent("printf 'a.lua:1\\n'")
  follow_from(pinned)
  eq(child.lua_get("_G.notes"), {})
  eq(child.lua_get("vim.api.nvim_get_current_win()"), dashboard)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
end

T["terminal"]["a code window that sets 'winfixbuf'"]["is skipped for another code window"] = function()
  local free = show_code("c.lua")
  child.cmd("split")
  local pinned = show_code("b.lua", true)
  agent("printf 'a.lua:1\\n'")
  -- The pinned window is the previous one, and comes first in the tab.
  follow_from(pinned)
  eq(child.lua_get("_G.notes"), {})
  eq(child.lua_get("vim.api.nvim_get_current_win()"), free)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
end

T["terminal"]["a code window that sets 'winfixbuf'"]["is used when it shows the file"] = function()
  local pinned = show_code("lua/duet/init.lua", true)
  agent("printf 'lua/duet/init.lua:7\\n'")
  child.lua("cursor_on('init.lua')")
  child.type_keys("gf")
  eq(child.lua_get("_G.notes"), {})
  eq(child.lua_get("vim.api.nvim_get_current_win()"), pinned)
  eq(child.lua_get("vim.fn.line('.')"), 7)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
end

T["terminal"]["a code window that sets 'winfixbuf'"]["is used when it shows the file by another name"] = function()
  -- Neovim resolves a symlinked directory in a buffer's name, but not a symlinked file.
  vim.uv.fs_symlink(root .. "/a.lua", root .. "/alias.lua")
  local pinned = show_code("alias.lua", true)
  eq(rel(child.lua_get("vim.api.nvim_buf_get_name(0)")), "alias.lua")
  agent("printf 'a.lua:1\\n'")
  child.lua("cursor_on('a.lua')")
  child.type_keys("gf")
  eq(child.lua_get("_G.notes"), {})
  eq(child.lua_get("vim.api.nvim_get_current_win()"), pinned)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
end

T["terminal"]["a start screen is replaced"] = MiniTest.new_set({
  parametrize = { { "snacks_dashboard" }, { "alpha" }, { "dashboard" }, { "ministarter" }, { "startify" } },
})

T["terminal"]["a start screen is replaced"]["with filetype %s"] = function(filetype)
  local dashboard = screen(filetype)
  agent("printf 'a.lua:1\\n'")
  follow_from()
  eq(child.lua_get("vim.api.nvim_get_current_win()"), dashboard)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  eq(child.lua_get("s:is_visible()"), true)
  eq(child.lua_get("_G.notes"), {})
end

T["terminal"]["a sidebar is not replaced"] = function()
  local sidebar = screen("neo-tree")
  child.lua("vim.wo.winfixwidth = true")
  agent("printf 'a.lua:1\\n'")
  follow_from()
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
  eq(child.lua_get("vim.api.nvim_get_current_win() ~= ...", { sidebar }), true)
  eq(child.lua_get("vim.bo[vim.api.nvim_win_get_buf(...)].filetype", { sidebar }), "neo-tree")
end

T["terminal"]["a start screen is not replaced"] = MiniTest.new_set({
  parametrize = { { "modified" }, { "winfixbuf" }, { "a terminal" }, { "replace_filetypes = {}" } },
})

T["terminal"]["a start screen is not replaced"]["when %s"] = function(kind)
  local dashboard = screen("snacks_dashboard")
  if kind == "modified" then
    -- Neovim never counts a `nofile` buffer as modified: an `acwrite` one can be.
    child.lua("vim.bo.buftype = 'acwrite'; vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })")
    eq(child.lua_get("vim.bo.modified"), true)
  elseif kind == "winfixbuf" then
    child.lua("vim.wo.winfixbuf = true")
  elseif kind == "a terminal" then
    -- One with a filetype the user listed, e.g. another plugin's terminal.
    child.lua([[
      vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
      vim.fn.jobstart({ "cat" }, { term = true })
      vim.bo.filetype = "snacks_dashboard"
    ]])
  end
  agent("printf 'a.lua:1\\n'", kind == "replace_filetypes = {}" and { links = { replace_filetypes = {} } } or {})
  follow_from()
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 3)
  eq(child.lua_get("vim.bo[vim.api.nvim_win_get_buf(...)].filetype", { dashboard }), "snacks_dashboard")
end

T["terminal"]["the previous start screen window is preferred, then the widest"] = function()
  local wide = screen("alpha")
  local narrow = screen("alpha", "topleft vertical 20 new")
  local sidebar = screen("neo-tree", "topleft vertical 15 new")
  agent("printf 'a.lua:1\\n'")
  follow_from(narrow)
  eq(child.lua_get("vim.api.nvim_get_current_win()"), narrow)
  -- The dashboard is gone from `narrow`; show one there again and come from the sidebar.
  screen("alpha")
  follow_from(sidebar)
  eq(child.lua_get("vim.api.nvim_get_current_win()"), wide)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 4)
end

T["terminal"]["the current start screen window is preferred"] = function()
  local wide = screen("alpha")
  local narrow = screen("alpha", "topleft vertical 20 new")
  agent("printf 'a.lua:1\\n'")
  -- open() called from a start screen, e.g. by a user's mapping, with another one as
  -- the previous window.
  child.lua("vim.api.nvim_set_current_win(...)", { wide })
  child.lua("vim.api.nvim_set_current_win(...)", { narrow })
  eq(child.lua_get("L.open({ path = 'a.lua' })"), true)
  eq(child.lua_get("vim.api.nvim_get_current_win()"), narrow)
end

T["terminal"]["of start screens as wide, the tallest is used"] = function()
  local tall = screen("alpha")
  screen("alpha", "aboveleft 3 new")
  local sidebar = screen("neo-tree", "topleft vertical 15 new")
  agent("printf 'a.lua:1\\n'")
  follow_from(sidebar)
  eq(child.lua_get("vim.api.nvim_get_current_win()"), tall)
end

T["terminal"]["a file that fails to open in place of a start screen"] = MiniTest.new_set({
  parametrize = { { "hide" }, { "unload" }, { "wipe" } },
})

T["terminal"]["a file that fails to open in place of a start screen"]["with bufhidden=%s"] = function(bufhidden)
  local dashboard = screen("snacks_dashboard")
  child.lua("vim.bo.bufhidden = ...", { bufhidden })
  local buf = child.lua_get("vim.api.nvim_get_current_buf()")
  agent("printf 'a.lua:1\\n'")
  child.lua([[vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "*/a.lua",
    callback = function() error("cannot read") end,
  })]])
  child.lua("cursor_on('a.lua')")
  child.type_keys("gf")
  local shown = child.lua_get("vim.api.nvim_win_get_buf(...)", { dashboard })
  if bufhidden == "hide" then
    -- The start screen comes back.
    eq(shown, buf)
  else
    -- It is gone: the window shows an empty buffer, not the one that failed.
    eq(child.lua_get("vim.api.nvim_buf_is_loaded(...)", { buf }), false)
    eq(
      child.lua_get("(function(b) return { vim.api.nvim_buf_get_name(b), vim.bo[b].buftype } end)(...)", { shown }),
      { "", "" }
    )
  end
  eq(child.lua_get("vim.fn.bufexists(...)", { root .. "/a.lua" }), 0)
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  eq(child.lua_get("{ s:is_visible(), where().terminal }"), { true, true })
  eq(child.lua_get("_G.notes[1].msg"):find("cannot open 'a.lua'", 1, true) ~= nil, true)
end

T["terminal"]["]l and [l move between links that resolve"] = function()
  agent("printf 'a.lua:1 nope.lua:2 b.lua:3\\nthen c.lua:4\\n'")
  local row = child.lua_get("cursor_on('a.lua')")
  local function pos()
    return child.lua_get("vim.api.nvim_win_get_cursor(0)")
  end
  child.type_keys("]l")
  eq(pos(), { row, 19 })
  child.type_keys("]l")
  eq(pos(), { row + 1, 5 })
  child.type_keys("[l")
  eq(pos(), { row, 19 })
  child.type_keys("]l", "2[l")
  eq(pos(), { row, 0 })
  child.type_keys("[l")
  eq(pos(), { row, 0 })
  eq(child.lua_get("_G.notes[1].msg"), "[duet] links: no previous link in the visible output")
  -- From inside a link, [l goes to the one before it, not to its start.
  child.lua("vim.api.nvim_win_set_cursor(0, ...)", { { row, 21 } })
  child.type_keys("[l")
  eq(pos(), { row, 0 })
end

T["terminal"]["keys can be turned off"] = function()
  agent("printf 'a.lua:1\\n'", { terminal = { keys = { gf = false } } })
  local maps = child.lua_get([[vim.api.nvim_buf_call(s.buf, function()
    return { vim.fn.maparg("gf", "n"), vim.fn.maparg("<CR>", "n", false, true).buffer }
  end)]])
  eq(maps, { "", 1 })
end

T["terminal"]["highlights links when enabled"] = function()
  agent("printf 'see a.lua:1 and nope.lua:2\\n'", { links = { highlight = true, debounce_ms = 10 } })
  child.lua("cursor_on('a.lua')")
  local ok = child.lua_get([[wait(function()
    local ns = vim.api.nvim_create_namespace("duet.links")
    return #vim.api.nvim_buf_get_extmarks(s.buf, ns, 0, -1, {}) == 1
  end)]])
  eq(ok, true)
  eq(child.lua_get("vim.fn.hlexists('DuetLink')"), 1)
end

T["terminal"]["highlights links while output keeps coming"] = function()
  -- Output every 20 ms, with the link coming once it has started, so a highlighter that
  -- waits for output to pause would not underline it until the end.
  agent(
    "for i in $(seq 1 10); do sleep 0.02; echo pre$i; done; printf 'see a.lua:1\\n'; "
      .. "for i in $(seq 1 100); do sleep 0.02; echo tick$i; done",
    { links = { highlight = true, debounce_ms = 50 } }
  )
  -- TextChangedT fires from the main loop in Terminal-mode: let the child run and poll it.
  child.lua("vim.api.nvim_set_current_win(s:window()); vim.cmd.startinsert()")
  local function underlined()
    return child.lua_get([[#vim.api.nvim_buf_get_extmarks(s.buf,
      vim.api.nvim_create_namespace("duet.links"), 0, -1, {}) > 0]])
  end
  local function done()
    return child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\\n")
      :find("tick100", 1, true) ~= nil]])
  end
  local seen = vim.wait(1500, underlined, 20)
  eq({ seen, done() }, { true, false })
end

T["terminal"]["does not highlight by default"] = function()
  agent("printf 'see a.lua:1\\n'")
  child.lua("cursor_on('a.lua'); vim.wait(150)")
  local count = child.lua_get([[#vim.api.nvim_buf_get_extmarks(s.buf,
    vim.api.nvim_create_namespace("duet.links"), 0, -1, {})]])
  eq(count, 0)
end

T["terminal"]["follows OSC 8 hyperlinks"] = MiniTest.new_set({
  parametrize = { { "file URI" }, { "relative path" } },
})

-- Skip the test when this Neovim does not report OSC 8 with TermRequest: no span appears.
local function require_osc8()
  local seen = child.lua_get([[wait(function()
    return #vim.api.nvim_buf_get_extmarks(s.buf, vim.api.nvim_create_namespace("duet.links.osc8"), 0, -1, {}) > 0
  end, 1000)]])
  if not seen then
    MiniTest.skip("TermRequest does not report OSC 8 on Neovim " .. tostring(child.lua_get("vim.version()")))
  end
  child.lua("vim.wait(100)") -- let the spans settle
end

---printf commands that print an OSC 8 hyperlink to `target` with `text`, between
---`before` and `after`.
local function osc8(target, text, before, after)
  return ("printf '%s\\033]8;;%s\\033\\\\%s\\033]8;;\\033\\\\%s\\n'"):format(before or "", target, text, after or "")
end

T["terminal"]["follows OSC 8 hyperlinks"]["with a %s"] = function(kind)
  local target = kind == "file URI" and ("file://" .. root .. "/lua/duet/init.lua#L5") or "lua/duet/init.lua#L5"
  agent(osc8(target, "Open me", "", " now"))
  child.lua("cursor_on('Open me')")
  require_osc8()
  child.type_keys("w", "gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 5 })
end

T["terminal"]["ignores an OSC 8 span the program wrote over"] = function()
  local target = "file://" .. root .. "/a.lua"
  agent(
    ("printf '\\033]8;;%s\\033\\\\Open me\\033]8;;\\033\\\\\\n'; sleep 0.2; printf '\\033[1A\\rOther b.lua\\n'"):format(
      target
    )
  )
  child.lua("cursor_on('Other')")
  child.type_keys("gf")
  -- The cursor is on "Other", where the stale link was: nothing opens.
  eq(child.lua_get("where().terminal"), true)
  child.lua("cursor_on('b.lua')")
  child.type_keys("gf")
  eq(rel(child.lua_get("where().name")), "b.lua")
end

T["terminal"]["places OSC 8 hyperlinks after multibyte text"] = MiniTest.new_set({
  parametrize = { { "⏺ " }, { "漢字 " } },
})

T["terminal"]["places OSC 8 hyperlinks after multibyte text"]["after %s"] = function(prefix)
  agent(osc8("file://" .. root .. "/lua/duet/init.lua#L5", "link", prefix, " end"))
  -- The last letter: a span placed by screen cells as bytes ends before it.
  child.lua("cursor_on('k end')")
  require_osc8()
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 5 })
  -- The space before the link is not part of it; such a span starts before it.
  child.lua("vim.cmd.wincmd('p'); cursor_on(' link')")
  child.type_keys("gf")
  eq(child.lua_get("where().terminal"), true)
end

T["terminal"]["keeps OSC 8 hyperlinks on their line while the scrollback is trimmed"] = function()
  -- The agent waits so the test can shrink the scrollback first; then output arrives in
  -- pieces, so lines are dropped from the top while the link's text is not in yet.
  local print_link = osc8("file://" .. root .. "/lua/duet/init.lua#L5", "LINK")
  agent(
    "sleep 0.3; for i in $(seq 1 60); do echo filler$i; done; "
      .. print_link
      .. "; for i in 1 2 3 4 5 6 7 8; do sleep 0.01; echo after$i; done"
  )
  child.lua("vim.bo[s.buf].scrollback = 3")
  child.lua("cursor_on('after8'); cursor_on('LINK')")
  require_osc8()
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 5 })
end

T["terminal"]["records OSC 8 hyperlinks at the bottom of the output"] = MiniTest.new_set({
  parametrize = {
    -- The link is on the last screen row and the screen scrolls, in pieces, before
    -- duet reads the link's text.
    {
      "while the screen scrolls",
      "for i in $(seq 1 60); do echo f$i; done; %s; "
        .. "for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.004; echo after$i; done",
    },
    { "after a long output", "for i in $(seq 1 200); do echo f$i; done; %s" },
  },
})

T["terminal"]["records OSC 8 hyperlinks at the bottom of the output"]["%s"] = function(_, script)
  agent(script:format(osc8("file://" .. root .. "/lua/duet/init.lua#L5", "LINK")))
  child.lua("cursor_on('LINK')")
  require_osc8()
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 5 })
end

T["terminal"]["keeps at most 500 OSC 8 hyperlinks"] = function()
  agent([[for i in $(seq 1 600); do printf '\033]8;;file:///x%d\033\\L\033]8;;\033\\\n' $i; done]])
  child.lua("cursor_on('L')")
  require_osc8()
  local count = child.lua_get([[(function()
    wait(function() return vim.api.nvim_buf_line_count(s.buf) >= 600 end)
    vim.wait(300)
    return #vim.api.nvim_buf_get_extmarks(s.buf, vim.api.nvim_create_namespace("duet.links.osc8"), 0, -1, {})
  end)()]])
  eq(count, 500)
end

T["terminal"]["a file that fails to open leaves the layout as it was"] = MiniTest.new_set({
  parametrize = { { "no code window" }, { "float" } },
})

T["terminal"]["a file that fails to open leaves the layout as it was"]["with %s"] = function(kind)
  local opts = kind == "float" and { terminal = { layout = "float" } } or {}
  agent("printf 'a.lua:1\\n'", opts)
  child.lua("cursor_on('a.lua')")
  if kind == "no code window" then
    child.lua("vim.cmd('only')")
  end
  child.lua([[vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "*/a.lua",
    callback = function() error("cannot read") end,
  })]])
  local before = child.lua_get("#vim.api.nvim_tabpage_list_wins(0)")
  local bufs = child.lua_get("#vim.fn.getbufinfo({ buflisted = 1 })")
  child.type_keys("gf")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), before)
  eq(child.lua_get("#vim.fn.getbufinfo({ buflisted = 1 })"), bufs)
  eq(child.lua_get("{ s:is_visible(), where().terminal }"), { true, true })
  eq(child.lua_get("_G.notes[1].msg"):find("cannot open 'a.lua'", 1, true) ~= nil, true)
end

T["terminal"]["a floating terminal that cannot be hidden opens nothing"] = function()
  agent("printf 'a.lua:1\\n'", { terminal = { layout = "float" } })
  child.lua("cursor_on('a.lua'); s.hide = function() return nil, 'cannot hide' end")
  child.type_keys("gf")
  eq(child.lua_get("{ s:is_visible(), where().terminal }"), { true, true })
  eq(child.lua_get("_G.notes[1].msg"), "[duet] links: cannot open 'a.lua': cannot hide")
end

T["terminal"]["follows an OSC 8 link printed over the previous frame"] = function()
  -- A TUI such as Claude Code redraws rows in place: when TermRequest comes, the row may
  -- still hold the previous frame's text, which is not the link's.
  local target = "file://" .. root .. "/lua/duet/init.lua#L5"
  agent("printf 'x OLDOLDOLD\\n'; sleep 0.2; printf '\\033[1A\\r'; " .. osc8(target, "LINK", "x ", "      "))
  child.lua("cursor_on('LINK')")
  require_osc8()
  child.type_keys("gf")
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 5 })
end

T["terminal"]["ignores text written over an OSC 8 link right after it"] = function()
  -- The row is rewritten before duet could have read it on a fixed delay.
  local target = "file://" .. root .. "/a.lua"
  agent(osc8(target, "LINK", "x ") .. "; sleep 0.015; printf '\\033[1A\\rx OTHER text\\n'")
  child.lua("cursor_on('OTHER')")
  require_osc8()
  child.type_keys("gf")
  eq(child.lua_get("where().terminal"), true)
end

-- open() -------------------------------------------------------------------------

-- Mouse clicks -------------------------------------------------------------------

-- printf commands that turn on mouse tracking (SGR), as TUIs such as Claude Code do.
local TRACK = "printf '\\033[?1000h\\033[?1006h'; "

---Wait for `needle` in the terminal and click it with `key` (e.g. "<C-LeftMouse>").
---@param needle string
---@param key? string default "<C-LeftMouse>"
---@param offset? integer cells after the start of `needle`
---@param rest? string keys sent after the press at the same place, e.g. "<C-LeftDrag>"
local function click(needle, key, offset, rest)
  -- Where `needle` is on the screen, as {row, col} for nvim_input() (0-based). Taken
  -- again for each probe: a float laid out again after it opened has moved.
  child.lua([[_G.locate = function(needle, offset)
      local row
      wait(function()
        row = vim.iter(ipairs(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false))):find(function(_, line)
          return line:find(needle, 1, true) ~= nil
        end)
        return row ~= nil
      end)
      assert(row, "not in the terminal: " .. needle)
      local col = vim.api.nvim_buf_get_lines(s.buf, row - 1, row, false)[1]:find(needle, 1, true)
      local pos = vim.fn.screenpos(s:window(), row, col)
      return { pos.row - 1, pos.col - 1 + offset }
    end]])
  local pos
  -- A click lands in a window only once the screen shows it: until then it goes to the
  -- window below (a new floating terminal), which a slow runner can be clicking. Probe
  -- with a button no test uses until a probe lands in the terminal's window.
  -- A probe that misses can leave Terminal mode or focus another window: put both back
  -- before the next one, as they were before probing.
  child.lua([[
    _G.probed = nil
    _G.modes = {}
    _G.probe_from = { win = vim.api.nvim_get_current_win(), terminal = vim.api.nvim_get_mode().mode == "t" }
    _G.probe_au = vim.api.nvim_create_autocmd("ModeChanged", {
      callback = function()
        table.insert(_G.modes, vim.v.event.old_mode .. ">" .. vim.v.event.new_mode)
      end,
    })
    vim.keymap.set({ "t", "n" }, "<X1Mouse>", function()
      _G.probed = vim.fn.getmousepos().winid
    end, { buffer = s.buf })
    _G.unprobe = function()
      _G.probed = nil
      local mode = vim.api.nvim_get_mode().mode
      if mode ~= "n" and mode ~= "t" then
        vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-N>"), "nx", false)
      end
      if vim.api.nvim_win_is_valid(_G.probe_from.win) then
        vim.api.nvim_set_current_win(_G.probe_from.win)
      end
      if _G.probe_from.terminal and vim.api.nvim_get_mode().mode ~= "t" then
        vim.cmd.startinsert()
        wait(function() return vim.api.nvim_get_mode().mode == "t" end, 500)
      end
    end
  ]])
  local landed = false
  for _ = 1, 100 do
    pos = child.lua_get("_G.locate(...)", { needle, offset or 0 })
    child.api.nvim_input(("<X1Mouse><%d,%d>"):format(pos[2], pos[1]))
    if child.lua_get("wait(function() return _G.probed ~= nil end, 100) and _G.probed == s:window()") then
      landed = true
      break
    end
    child.lua("_G.unprobe(); vim.wait(20)")
  end
  child.lua("vim.keymap.del({ 't', 'n' }, '<X1Mouse>', { buffer = s.buf }); vim.api.nvim_del_autocmd(_G.probe_au)")
  if not landed then
    -- What the probes saw, for a runner where they never land.
    landed = child.lua_get(
      [[vim.inspect({
        pos = ...,
        win = s:window(),
        config = s:window() and vim.api.nvim_win_get_config(s:window()),
        mode = vim.api.nvim_get_mode().mode,
        modes = _G.modes,
        current = vim.api.nvim_get_current_win(),
        mouse = vim.o.mouse,
        wins = vim.api.nvim_tabpage_list_wins(0),
        probed = _G.probed,
      })]],
      { pos }
    )
  end
  eq({ needle, landed }, { needle, true })
  local keys = vim.iter({ key or "<C-LeftMouse>", rest and vim.split(rest, " ") or nil }):flatten():totable()
  for _, k in ipairs(keys) do
    child.api.nvim_input(("%s<%d,%d>"):format(k, pos[2], pos[1]))
  end
  -- Time for a click that should do nothing to do something; others are waited for.
  vim.uv.sleep(50)
end

-- Enter Terminal mode in the agent's terminal.
local function terminal_mode()
  child.lua("vim.api.nvim_set_current_win(s:window()); vim.cmd.startinsert()")
  eq(child.lua_get("wait(function() return vim.api.nvim_get_mode().mode == 't' end)"), true)
end

-- Wait for the click to open a file: the current buffer is no longer a terminal.
local function opened()
  eq(child.lua_get("wait(function() return vim.bo.buftype ~= 'terminal' end)"), true)
end

---The mouse reports the job read: terminal echo of SGR sequences, e.g. `^[[<0;3;1M`.
local function reports()
  return child.lua_get([[vim.iter(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false))
    :filter(function(line) return line:find("^[[<", 1, true) ~= nil end)
    :totable()]])
end

T["mouse"] = MiniTest.new_set({ hooks = { pre_case = start, post_once = child.stop } })

T["mouse"]["Ctrl+click in Terminal mode opens the file at the line"] = function()
  agent("printf 'see lua/duet/init.lua:10 now\\n'")
  local code = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  terminal_mode()
  click("init.lua", nil, 3)
  opened()
  local at = child.lua_get("where()")
  eq(rel(at.name), "lua/duet/init.lua")
  eq({ at.line, at.terminal }, { 10, false })
  eq(child.lua_get("vim.api.nvim_get_current_win()"), code)
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "n")
  eq(child.lua_get("_G.notes"), {})
end

T["mouse"]["Ctrl+click opens a link while the job tracks the mouse"] = function()
  agent(TRACK .. "printf 'plain text\\na.lua:1:1\\n'")
  terminal_mode()
  click("plain", "<LeftMouse>")
  eq(
    child.lua_get(
      "wait(function() return #vim.fn.getbufline(s.buf, 1, '$') > 0 and vim.fn.join(vim.fn.getbufline(s.buf, 1, '$')):find('[[<0;', 1, true) ~= nil end)"
    ),
    true
  )
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "t")
  click("a.lua")
  opened()
  eq({ rel(child.lua_get("where().name")), child.lua_get("where().line") }, { "a.lua", 1 })
  -- The job got the plain click only: press and release.
  eq(#reports(), 1)
  eq(reports()[1]:find("[[<16;", 1, true), nil)
end

T["mouse"]["Ctrl+click in Normal mode opens the file"] = function()
  agent("printf 'lua/duet/init.lua:12:3\\n'")
  child.lua("vim.api.nvim_set_current_win(s:window())")
  click("lua/duet")
  opened()
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line, at.col }, { "lua/duet/init.lua", 12, 3 })
end

T["mouse"]["Ctrl+click does nothing where there is no link"] = MiniTest.new_set({
  parametrize = { { "nothing here" }, { "missing/nope.lua:3" }, { "past the end" } },
})

T["mouse"]["Ctrl+click does nothing where there is no link"]["on %s"] = function(text)
  agent(TRACK .. ("printf '%s\\n'"):format(text))
  terminal_mode()
  local win = child.lua_get("vim.api.nvim_get_current_win()")
  click(text, nil, text == "past the end" and #text + 5 or 2, "<C-LeftDrag> <C-LeftRelease>")
  eq(child.lua_get("vim.api.nvim_get_current_win()"), win)
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "t")
  eq(child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"), 2)
  eq(child.lua_get("_G.notes"), {})
  eq(child.lua_get("vim.v.errmsg"), "")
  eq(reports(), {})
end

T["mouse"]["a Ctrl+drag on text without a link keeps Terminal mode"] = function()
  agent("printf 'nothing here\\n'")
  terminal_mode()
  click("nothing", nil, 2, "<C-LeftDrag> <C-LeftRelease>")
  eq(child.lua_get("{ vim.api.nvim_get_mode().mode, where().terminal }"), { "t", true })
end

T["mouse"]["a click kept for itself ends with its release, with or without Ctrl"] = function()
  agent(TRACK .. "printf 'nothing here\\n'")
  child.o.mousetime = 1 -- the next click is not a double-click
  terminal_mode()
  -- CTRL let go before the button: the release comes without it.
  click("nothing", nil, 2, "<C-LeftDrag> <LeftRelease>")
  eq(reports(), {})
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "t")
  -- The next plain click goes to the agent whole.
  click("here", "<LeftMouse>", 0, "<LeftRelease>")
  eq(
    child.lua_get(
      "wait(function() return vim.fn.join(vim.fn.getbufline(s.buf, 1, '$')):find('[[<0;', 1, true) ~= nil and vim.fn.join(vim.fn.getbufline(s.buf, 1, '$')):find('m', 1, true) ~= nil end)"
    ),
    true
  )
  eq(child.lua_get("vim.fn.maparg('<LeftRelease>', 't')"), "")
end

T["mouse"]["a release mapped in terminal.keys keeps its action"] = function()
  agent("printf 'nothing here\\n'", { terminal = { keys = { ["<C-LeftRelease>"] = "hide" } } })
  terminal_mode()
  click("nothing", nil, 2, "<C-LeftRelease>")
  eq(child.lua_get("wait(function() return not s:is_visible() end)"), true)
end

T["mouse"]["Ctrl+click on the number column is not a click on the text"] = function()
  agent("printf 'a.lua:1\\n'")
  child.lua("vim.api.nvim_set_current_win(s:window()); vim.wo.number = true; vim.wo.signcolumn = 'yes'")
  click("a.lua", nil, -3)
  eq(child.lua_get("where().terminal"), true)
  eq(child.lua_get("_G.notes"), {})
end

T["mouse"]["Ctrl+click follows an OSC 8 hyperlink"] = function()
  agent(osc8("lua/duet/init.lua#L5", "Open me", "", " now"))
  child.lua("cursor_on('Open me')")
  require_osc8()
  terminal_mode()
  click("Open me", nil, 5)
  opened()
  local at = child.lua_get("where()")
  eq({ rel(at.name), at.line }, { "lua/duet/init.lua", 5 })
end

T["mouse"]["Ctrl+click hides a floating terminal"] = function()
  agent("printf 'a.lua:1\\n'", { terminal = { layout = "float" } })
  terminal_mode()
  click("a.lua")
  opened()
  eq(rel(child.lua_get("where().name")), "a.lua")
  eq(child.lua_get("s:is_visible()"), false)
end

T["mouse"]["a link that fails to open keeps Terminal mode"] = function()
  agent("printf 'a.lua:1\n'", { terminal = { layout = "float" } })
  child.lua("s.hide = function() return nil, 'cannot hide' end")
  terminal_mode()
  click("a.lua")
  eq(child.lua_get("wait(function() return #_G.notes > 0 end)"), true)
  eq(child.lua_get("_G.notes[1].msg"), "[duet] links: cannot open 'a.lua': cannot hide")
  eq(child.lua_get("{ s:is_visible(), where().terminal }"), { true, true })
  eq(child.lua_get("wait(function() return vim.api.nvim_get_mode().mode == 't' end)"), true)
end

T["mouse"]["Ctrl+click on another window does what it does without duet"] = function()
  agent("printf 'a.lua:1\\n'")
  local code = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  terminal_mode()
  local pos = child.lua_get("vim.fn.win_screenpos(...)", { code })
  child.api.nvim_input(("<C-LeftMouse><%d,%d>"):format(pos[2], pos[1]))
  opened()
  eq(child.lua_get("vim.api.nvim_get_current_win()"), code)
end

---Click the top left of the code window with `keys` (e.g. "2<C-LeftMouse>").
---@param code integer the code window
---@param keys string
local function click_code(code, keys)
  local pos = child.lua_get("vim.fn.win_screenpos(...)", { code })
  child.api.nvim_input(("%s<%d,%d>"):format(keys, pos[2] - 1, pos[1] - 1))
end

T["mouse"]["Ctrl+click on another window runs your own mapping"] = MiniTest.new_set({
  parametrize = {
    -- { how, mode clicked in, mapping (Lua, sets _G.hit), keys, want }
    {
      "a Normal-mode callback, with the count",
      "n",
      [[vim.keymap.set("n", "<C-LeftMouse>", function()
        _G.hit = { mode = vim.api.nvim_get_mode().mode, count = vim.v.count }
      end)]],
      "2<C-LeftMouse>",
      { mode = "nt", count = 2, code = false },
    },
    {
      "a Normal-mode callback, from Terminal mode",
      "t",
      [[vim.keymap.set("n", "<C-LeftMouse>", function()
        _G.hit = { mode = vim.api.nvim_get_mode().mode, count = vim.v.count }
      end)]],
      "<C-LeftMouse>",
      { mode = "nt", count = 0, code = false },
    },
    {
      "a Terminal-mode callback",
      "t",
      [[vim.keymap.set("t", "<C-LeftMouse>", function()
        _G.hit = { mode = vim.api.nvim_get_mode().mode, count = vim.v.count }
      end)]],
      "<C-LeftMouse>",
      { mode = "t", count = 0, code = false },
    },
    {
      "keys",
      "n",
      [[vim.keymap.set("n", "<C-LeftMouse>", "<LeftMouse><Cmd>lua _G.hit = { count = vim.v.count }<CR>")]],
      "<C-LeftMouse>",
      { count = 0, code = true },
    },
    {
      "keys, with the count",
      "n",
      [[vim.keymap.set("n", "<C-LeftMouse>", "<Cmd>lua _G.hit = { count = vim.v.count }<CR>")]],
      "3<C-LeftMouse>",
      { count = 3, code = false },
    },
    {
      "keys that start with the click, remapped",
      "n",
      -- Their <C-LeftMouse> is Neovim's, not this mapping again: a jump to tag "foo".
      [[vim.keymap.set("n", "<C-LeftMouse>", "<C-LeftMouse><Cmd>lua _G.hit = { count = 0 }<CR>", { remap = true })]],
      "<C-LeftMouse>",
      { count = 0, code = true, name = "a.lua" },
    },
    {
      "the register",
      "n",
      [[vim.keymap.set("n", "<C-LeftMouse>", "<Cmd>lua _G.hit = { count = vim.v.count, register = vim.v.register }<CR>")]],
      '"a2<C-LeftMouse>',
      { count = 2, register = "a", code = false },
    },
    {
      "a Vimscript expression in its script",
      "n",
      [[local file = vim.fn.tempname() .. ".vim"
      vim.fn.writefile({
        "function! s:Pick() abort",
        "  return \"\\<Cmd>lua _G.hit = { count = vim.v.count }\\<CR>\"",
        "endfunction",
        "nnoremap <expr> <C-LeftMouse> <SID>Pick()",
      }, file)
      vim.cmd.source(file)]],
      "2<C-LeftMouse>",
      { count = 2, code = false },
    },
    {
      "a Vimscript expression with keys in its {rhs}",
      "n",
      [[vim.cmd("nnoremap <expr> <C-LeftMouse> v:count ? '<Cmd>lua _G.hit = { count = vim.v.count }<CR>' : ''")]],
      "4<C-LeftMouse>",
      { count = 4, code = false },
    },
    {
      "keys with <script>, which map only script-local keys",
      "n",
      [[vim.keymap.set("n", "zz", "<Cmd>lua _G.wrong = true<CR>")
      vim.cmd("nmap <script> <C-LeftMouse> <LeftMouse>zz<Cmd>lua _G.hit = { count = 0 }<CR>")]],
      "<C-LeftMouse>",
      { count = 0, code = true },
    },
    {
      "an expression",
      "t",
      [[vim.keymap.set("n", "<C-LeftMouse>", function()
        _G.hit = { count = vim.v.count }
        return "<LeftMouse>"
      end, { expr = true })]],
      "<C-LeftMouse>",
      { count = 0, code = true },
    },
  },
})

T["mouse"]["Ctrl+click on another window runs your own mapping"]["%s"] = function(_, mode, mapping, keys, want)
  child.fn.writefile({ "foo\ta.lua\t1" }, root .. "/tags")
  agent("printf 'a.lua:1\\n'")
  local code = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(code), 0, -1, false, { "foo" })
  child.lua(mapping)
  if mode == "t" then
    terminal_mode()
  else
    child.lua("vim.api.nvim_set_current_win(s:window())")
  end
  click_code(code, keys)
  eq(child.lua_get("wait(function() return _G.hit ~= nil end)"), true)
  local hit = child.lua_get("_G.hit")
  eq({ hit.mode, hit.count, hit.register }, { want.mode, want.count, want.register })
  eq(child.lua_get("_G.wrong"), vim.NIL)
  -- The code window is current only if the mapping clicked it: <C-LeftMouse> itself
  -- would make it so.
  eq(
    child.lua(
      "local code = ...; return wait(function() return vim.api.nvim_get_current_win() == code end, 200)",
      { code }
    ),
    want.code
  )
  if want.name then
    eq(rel(child.lua_get("where().name")), want.name)
  end
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["mouse"]["a double Ctrl+click on a link opens it once, until the next key"] = MiniTest.new_set({
  -- Neovim counts a fifth press as one again.
  parametrize = { { "double", 2 }, { "triple", 3 }, { "five-times", 5 } },
})

T["mouse"]["a double Ctrl+click on a link opens it once, until the next key"]["%s"] = function(_, presses)
  agent(TRACK .. "printf 'a.lua:1\\n'")
  local code = child.lua_get("vim.fn.win_getid(vim.fn.winnr('#'))")
  local listeners = child.lua_get("vim.on_key()")
  child.lua([[local open = L.open
    L.open = function(...)
      _G.opens = (_G.opens or 0) + 1
      return open(...)
    end]])
  terminal_mode()
  local rest = { "<C-LeftRelease>" }
  for _ = 2, presses do
    vim.list_extend(rest, { "<C-LeftMouse>", "<C-LeftDrag>", "<C-LeftRelease>" })
  end
  click("a.lua", nil, 0, table.concat(rest, " "))
  opened()
  vim.uv.sleep(100)
  eq(child.lua_get("{ vim.api.nvim_get_current_win(), vim.v.errmsg }"), { code, "" })
  eq(rel(child.lua_get("where().name")), "a.lua")
  eq(child.lua_get("_G.opens"), 1)
  eq(reports(), {})
  -- The next key typed ends it.
  child.type_keys("<Esc>")
  eq(child.lua_get("vim.on_key()"), listeners)
end

T["mouse"]["a double Ctrl+click on text without a link does nothing"] = function()
  agent(TRACK .. "printf 'nothing here\\n'")
  terminal_mode()
  click("nothing", nil, 2, "<C-LeftRelease> <C-LeftMouse> <C-LeftRelease>")
  vim.uv.sleep(100)
  eq(reports(), {})
  eq(child.lua_get("{ vim.api.nvim_get_mode().mode, vim.v.errmsg }"), { "t", "" })
end

T["mouse"]["a double click mapped in terminal.keys keeps its own release"] = function()
  agent(TRACK .. "printf 'nothing here\\n'", { terminal = { keys = { ["<2-C-LeftMouse>"] = "open_link_mouse" } } })
  terminal_mode()
  click("nothing", nil, 2, "<C-LeftRelease> <C-LeftMouse> <C-LeftRelease>")
  vim.uv.sleep(100)
  eq(reports(), {})
  eq(child.lua_get("{ vim.fn.maparg('<2-C-LeftRelease>', 't'), vim.fn.maparg('<C-LeftRelease>', 't') }"), { "", "" })
  eq(child.lua_get("vim.api.nvim_get_mode().mode"), "t")
end

T["mouse"]["a Ctrl+click after a double Ctrl+click opens a link again"] = function()
  agent("printf 'a.lua:1\\nb.lua:1\\n'")
  terminal_mode()
  click("a.lua", nil, 0, "<C-LeftRelease> <C-LeftMouse> <C-LeftRelease>")
  opened()
  child.o.mousetime = 1 -- the next click is a new one
  vim.uv.sleep(20)
  terminal_mode()
  click("b.lua")
  eq(child.lua_get("wait(function() return vim.api.nvim_buf_get_name(0):find('b.lua', 1, true) ~= nil end)"), true)
end

T["mouse"]["the click can be rebound"] = function()
  agent(TRACK .. "printf 'a.lua:1\\n'", {
    terminal = { keys = { ["<C-LeftMouse>"] = false, ["<M-LeftMouse>"] = "open_link_mouse" } },
  })
  child.o.mousetime = 1 -- the second click is not a double-click
  terminal_mode()
  click("a.lua")
  -- Not mapped any more: the job gets the click, with Ctrl (16).
  eq(
    child.lua_get(
      "wait(function() return vim.fn.join(vim.fn.getbufline(s.buf, 1, '$')):find('[[<16;', 1, true) ~= nil end)"
    ),
    true
  )
  eq(child.lua_get("where().terminal"), true)
  click("a.lua", "<M-LeftMouse>")
  opened()
  eq(rel(child.lua_get("where().name")), "a.lua")
end

T["mouse"]["the click can be turned off"] = function()
  agent("printf 'a.lua:1\\n'", { terminal = { keys = { ["<C-LeftMouse>"] = false } } })
  local maps = child.lua_get([[vim.api.nvim_buf_call(s.buf, function()
    return { vim.fn.maparg("<C-LeftMouse>", "t"), vim.fn.maparg("<C-LeftMouse>", "n") }
  end)]])
  eq(maps, { "", "" })
end

T["open()"] = MiniTest.new_set({ hooks = { pre_case = start, post_once = child.stop } })

T["open()"]["clamps a line past the end and flashes the range"] = function()
  local info = child.lua([[
    assert(L.open({ path = "lua/duet/init.lua", line = 38, end_line = 99 }))
    local ns = vim.api.nvim_create_namespace("duet.links.flash")
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    return { line = vim.fn.line("."), flashed = #marks > 0 }
  ]])
  eq(info, { line = 38, flashed = true })
  local cleared = child.lua_get([[wait(function()
    return #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("duet.links.flash"), 0, -1, {}) == 0
  end, 2000)]])
  eq(cleared, true)
end

T["open()"]["adds a jump to the jumplist"] = function()
  child.lua([[
    assert(L.open({ path = "lua/duet/init.lua", line = 5 }))
    assert(L.open({ path = "lua/duet/init.lua", line = 30 }))
  ]])
  child.type_keys("<C-o>")
  eq(child.lua_get("vim.fn.line('.')"), 5)
end

T["open()"]["opens a directory"] = function()
  child.fn.mkdir(root .. "/dir")
  eq(child.lua_get("L.open({ path = 'dir' })"), true)
end

T["open()"]["returns an error for a missing file"] = function()
  eq(child.lua_get("{ L.open({ path = 'nope.lua' }) }"), { vim.NIL, "links: no such file 'nope.lua'" })
end

return T
