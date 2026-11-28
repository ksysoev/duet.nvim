local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = h.reset_modules,
  },
})

local RUN = "/run/duet/s1"
local MCP_PATH = RUN .. "/mcp.json"
local SETTINGS_PATH = RUN .. "/settings.json"

local function claude()
  return require("duet.agents").get("claude")
end

local function spec(extra)
  return vim.tbl_extend("force", { cwd = "/work", session_id = "s1", run_dir = RUN }, extra or {})
end

---Decode the plan's files so tests don't depend on JSON key order.
local function decoded_files(plan)
  local files = {}
  for _, file in ipairs(plan.files) do
    files[file.path] = vim.json.decode(file.content, { luanil = { object = true, array = true } })
  end
  return files
end

local MCP = { name = "duet", command = { "/bin/nvim", "-l", "/p/bridge/mcp.lua" }, env = { NVIM = "/s.sock" } }

local function mcp_json(env)
  return {
    mcpServers = {
      duet = { type = "stdio", command = "/bin/nvim", args = { "-l", "/p/bridge/mcp.lua" }, env = env },
    },
  }
end

local function settings_json(command, timeout)
  return {
    hooks = {
      PreToolUse = {
        { matcher = "ExitPlanMode", hooks = { { type = "command", command = command, timeout = timeout } } },
      },
    },
  }
end

local HOOK = { command = { "/bin/nvim", "-l", "/p/bridge/hook.lua", "plan_review" } }
local HOOK_CMD = "/bin/nvim -l /p/bridge/hook.lua plan_review"

T["launch()"] = MiniTest.new_set()

local launch_cases = {
  {
    name = "minimal spec",
    spec = {},
    argv = { "claude" },
    env = {},
    files = {},
  },
  {
    name = "mcp server",
    spec = { mcp = MCP },
    argv = { "claude", "--mcp-config", MCP_PATH },
    env = {},
    files = { [MCP_PATH] = mcp_json({ NVIM = "/s.sock" }) },
  },
  {
    name = "plan hook with the default timeout",
    spec = { hooks = { plan_review = HOOK } },
    argv = { "claude", "--settings", SETTINGS_PATH },
    env = {},
    files = { [SETTINGS_PATH] = settings_json(HOOK_CMD, 3600) },
  },
  {
    name = "plan hook with a timeout",
    spec = { hooks = { plan_review = vim.tbl_extend("force", HOOK, { timeout_s = 120 }) } },
    argv = { "claude", "--settings", SETTINGS_PATH },
    env = {},
    files = { [SETTINGS_PATH] = settings_json(HOOK_CMD, 120) },
  },
  {
    name = "empty hooks table",
    spec = { hooks = {} },
    argv = { "claude" },
    env = {},
    files = {},
  },
  {
    name = "system prompt",
    spec = { system_prompt = "Use duet.\nCall open_file." },
    argv = { "claude", "--append-system-prompt", "Use duet.\nCall open_file." },
    env = {},
    files = {},
  },
  {
    name = "tool timeout",
    spec = { tool_timeout_ms = 3600000 },
    argv = { "claude" },
    env = { MCP_TOOL_TIMEOUT = "3600000" },
    files = {},
  },
  {
    name = "everything, with user args after cmd and before duet's flags",
    opts = { args = { "--model", "opus" }, env = { EXTRA = "1" } },
    spec = { mcp = MCP, hooks = { plan_review = HOOK }, system_prompt = "hi", tool_timeout_ms = 1000 },
    argv = {
      "claude",
      "--model",
      "opus",
      "--mcp-config",
      MCP_PATH,
      "--settings",
      SETTINGS_PATH,
      "--append-system-prompt",
      "hi",
    },
    env = { MCP_TOOL_TIMEOUT = "1000", EXTRA = "1" },
    files = { [MCP_PATH] = mcp_json({ NVIM = "/s.sock" }), [SETTINGS_PATH] = settings_json(HOOK_CMD, 3600) },
  },
}

for _, case in ipairs(launch_cases) do
  T["launch()"][case.name] = function()
    require("duet.config").setup({ agents = { claude = case.opts } })
    local plan = claude():launch(spec(case.spec))
    eq(plan.argv, case.argv)
    eq(plan.env, case.env)
    eq(decoded_files(plan), case.files)
  end
end

T["launch()"]["encodes an empty mcp env as an object"] = function()
  local plan = claude():launch(spec({ mcp = vim.tbl_extend("force", MCP, { env = {} }) }))
  eq(plan.files[1].content:find('"env":{}', 1, true) ~= nil, true)
end

T["launch()"]["quotes the hook command for sh"] = function()
  local argv = { "/Applications/My Neovim.app/nvim", "-l", "it's.lua", "$HOME", "plain-word_1.0" }
  local plan = claude():launch(spec({ hooks = { plan_review = { command = argv } } }))
  local command = vim.json.decode(plan.files[1].content).hooks.PreToolUse[1].hooks[1].command
  eq(command, [['/Applications/My Neovim.app/nvim' -l 'it'\''s.lua' '$HOME' plain-word_1.0]])
  -- The shell splits it back into the original words.
  local script = 'for a in "$@"; do printf "%s\\n" "$a"; done'
  local out = h.run({ "sh", "-c", ("set -- %s; %s"):format(command, script) })
  eq(vim.split(out, "\n", { trimempty = true }), argv)
end

T["launch()"]["does no I/O"] = function()
  local run_dir = vim.fn.tempname()
  claude():launch({ cwd = "/w", session_id = "s", run_dir = run_dir, mcp = MCP, hooks = { plan_review = HOOK } })
  eq(vim.uv.fs_stat(run_dir), nil)
end

T["launch()"]["requires run_dir"] = function()
  MiniTest.expect.error(function()
    claude():launch({ cwd = "/w", session_id = "s" })
  end)
end

T["is_ready()"] = MiniTest.new_set()

local RULE = string.rep("─", 100)

-- Captured from Claude Code 2.1.330 in a 100x40 Neovim terminal.
local READY = {
  " ▐▛███▛█   Claude Code v2.1.330",
  "▝▜██████▀  Opus 5.5 · Claude Pro",
  " ▝▝   ▝▝   ~/Documents/Dev/duet.nvim",
  string.rep(" ", 80) .. "◐ medium · /effort",
  RULE,
  '❯ Try "how do I log an error?"',
  RULE,
  "  ⏵⏵ auto mode on (shift+tab to cycle)",
  "",
}

local ready_cases = {
  { name = "input prompt", lines = READY, ready = true },
  {
    name = "input prompt with typed text and trailing spaces",
    lines = { RULE .. "   ", "❯ fix the bug" .. string.rep(" ", 20), RULE },
    ready = true,
  },
  { name = "empty screen", lines = {}, ready = false },
  { name = "blank lines", lines = { "", "", "" }, ready = false },
  { name = "only the logo while loading", lines = vim.list_slice(READY, 1, 3), ready = false },
  {
    name = "a menu inside a box",
    lines = {
      "╭" .. RULE .. "╮",
      "│ Do you trust the files in this folder? │",
      "│ ❯ 1. Yes, proceed                      │",
      "│   2. No, exit                          │",
      "╰" .. RULE .. "╯",
    },
    ready = false,
  },
  { name = "a numbered choice below a rule", lines = { RULE, "❯ 1. Yes", "  2. No" }, ready = false },
  -- Captured from Claude Code 2.1.330 in an 80-column Neovim terminal, run with
  -- `--permission-mode manual` (the first two cut short and without their blank lines).
  {
    name = "busy with a reply: the input box stays",
    lines = {
      "❯ Line one of a test message.",
      "  Line two.",
      "· Wrangling…",
      string.rep("─", 80),
      "❯",
      string.rep("─", 80),
      "  ⏸ manual mode on · esc to interrupt",
    },
    ready = true,
  },
  {
    name = "a permission dialog",
    lines = {
      "❯ Use the Bash tool to run exactly: touch created.txt",
      "⏺ Bash(touch created.txt)",
      "  ⎿  Waiting…",
      string.rep("─", 80),
      " Bash command",
      " Create empty file created.txt",
      string.rep("╌", 80),
      " touch created.txt",
      string.rep("╌", 80),
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. Yes, and always allow access to",
      "   3. Yes, and switch to auto mode · auto mode handles these prompts for you",
      "   4. No",
      " Esc to cancel · Tab to amend",
    },
    ready = false,
  },
  {
    -- Captured: Claude Code 2.1.330 puts a no-break space after the `!`.
    name = "shell mode: the prompt is ! and a no-break space",
    lines = {
      "❯ an earlier message",
      "⏺ an answer",
      string.rep("─", 80),
      "!\194\160echo duet-ok",
      string.rep("─", 80),
      "  ! for shell mode",
    },
    ready = true,
  },
  {
    name = "shell mode: the prompt is ! and a space",
    lines = {
      "❯ an earlier message",
      "⏺ an answer",
      string.rep("─", 80),
      "! echo hi",
      string.rep("─", 80),
      "  ! for shell mode",
    },
    ready = true,
  },
  {
    name = "shell mode with nothing typed",
    lines = { string.rep("─", 80), "!", string.rep("─", 80) },
    ready = true,
  },
  { name = "a ! that isn't a prompt", lines = { string.rep("─", 80), "!important" }, ready = false },
  {
    name = "an old input box above a permission dialog",
    lines = {
      string.rep("─", 80),
      "❯ ",
      string.rep("─", 80),
      "⏺ Bash(touch created.txt)",
      string.rep("─", 80),
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. No",
    },
    ready = false,
  },
  {
    name = "an old shell prompt above a permission dialog",
    lines = {
      string.rep("─", 80),
      "! ls",
      string.rep("─", 80),
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. No",
    },
    ready = false,
  },
  {
    name = "the trust dialog, without a box or numbers",
    lines = {
      string.rep("─", 80),
      " Accessing workspace:",
      "",
      " /tmp/proj",
      "",
      " Quick safety check: Is this a project you created or one you trust?",
      "",
      " ❯ No, exit",
      "   Yes, I trust this folder",
      "",
      " Enter to confirm · Esc to cancel",
    },
    ready = false,
  },
  { name = "prompt marker without a rule", lines = { "some output", "❯ text" }, ready = false },
  -- Captured from Claude Code 2.1.330 in an 80-column Neovim terminal, after `/copy` was
  -- sent: the live input box has a no-break space after its `❯`.
  {
    name = "the slash-command menu in a Neovim terminal",
    lines = {
      " ▐▛███▛█   Claude Code v2.1.330",
      "▝▜██████▀  Opus 5.5 · Claude Pro",
      " ▝▝   ▝▝   ~/Documents/Dev/duet.nvim",
      "",
      "",
      "❯ /clear" .. string.rep(" ", 72),
      "",
      string.rep("─", 80),
      "❯\194\160/copy",
      string.rep("─", 80),
      "  ❯ /copy                       Copy the last response to clipboard (/copy 2",
      "                                for the one before)",
      "    /fork                       Copy this conversation into a new background",
      "                                session and keep working here",
    },
    ready = true,
  },
  -- Captured from Claude Code 2.1.330 in a 100-column terminal, after pasting `/clear`.
  {
    name = "the slash-command menu below the input box",
    lines = {
      " ▐▛███▛█   Claude Code v2.1.330",
      "▝▜██████▀  Opus 5.5 · Claude Pro",
      " ▝▝   ▝▝   ~/Documents/Dev/duet.nvim",
      "",
      "",
      RULE,
      "❯ /clear",
      RULE,
      "  ❯ /clear                      Start a new session with empty context; loops carry over, and the",
      "                                old one stays in /resume",
      "",
      "",
    },
    ready = true,
  },
  -- Captured likewise after pasting `/co` (cut short).
  {
    name = "the slash-command menu with several matches",
    lines = {
      "❯ /copy",
      "  ⎿  No assistant message to copy",
      RULE,
      "❯ /co",
      RULE,
      "  ❯ /copy                       Copy the last response to clipboard (/copy 2 for the one before)",
      "    /color                      Set the prompt bar color for this session",
      "    /config                     Open settings",
      "    /usage (cost)               Show session cost, plan usage, and activity stats",
    },
    ready = true,
  },
  {
    -- From the issue: a notice between the input box and the menu.
    name = "the slash-command menu below a notice",
    lines = {
      RULE,
      "❯ /clear",
      RULE,
      "  ⚠ Transcript saving is off — …",
      "  ❯ /clear                      Start a new session with empty context; …",
    },
    ready = true,
  },
  {
    -- Captured likewise after pasting `/compact keep the tests`: arguments close the menu.
    name = "a slash command with arguments",
    lines = {
      RULE,
      "❯ /compact keep the tests",
      RULE,
      "  ⏵⏵ auto mode on (shift+tab to cycle)",
      string.rep(" ", 70) .. "ctrl+y to paste deleted text",
    },
    ready = true,
  },
  {
    name = "no command matches what was typed",
    lines = { RULE, "❯ /nosuchcmd", RULE, '  No commands match "/nosuchcmd"' },
    ready = true,
  },
  {
    name = "a dialog choice that starts with a slash",
    lines = {
      RULE,
      "❯ ",
      RULE,
      "⏺ an answer",
      RULE,
      " Pick a directory",
      " ❯ /tmp/a",
      "   /tmp/b",
    },
    ready = false,
  },
  {
    name = "an old slash-command menu above a permission dialog",
    lines = {
      RULE,
      "❯ /clear",
      RULE,
      "  ❯ /clear   Start a new session",
      "⏺ Bash(touch created.txt)",
      RULE,
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. No",
    },
    ready = false,
  },
  {
    name = "a dialog choice that starts with a slash, right below an old input box",
    lines = { RULE, "❯ ", RULE, " Pick a directory", " ❯ /tmp/a", "   /tmp/b" },
    ready = false,
  },
  {
    name = "an old slash-command menu above newer output",
    lines = { RULE, "❯ /compact", RULE, "  ❯ /compact   Free up context", "⏺ Compacting…" },
    ready = false,
  },
  {
    name = "an old slash-command menu above a spinner",
    lines = { RULE, "❯ /compact", RULE, "  ❯ /compact   Free up context", "", "· Compacting…" },
    ready = false,
  },
  {
    name = "an old slash-command menu above a dialog without a choice marker",
    lines = { RULE, "❯ /clear", RULE, "  ❯ /clear   Start a new session", RULE, " Press Enter to continue" },
    ready = false,
  },
  {
    name = "a dialog choice that starts with a slash, below an old box holding a command",
    lines = { RULE, "❯ /add-dir", RULE, " Pick a directory", " ❯ /tmp/a", "   /tmp/b" },
    ready = false,
  },
  {
    name = "an old slash-command menu above an indented result",
    lines = { RULE, "❯ /compact", RULE, "  ❯ /compact   Free up context", "  ⎿  Compacted" },
    ready = false,
  },
  {
    name = "an old slash-command menu above indented dialog text",
    lines = { RULE, "❯ /clear", RULE, "  ❯ /clear   Start a new session", " Press Enter to continue" },
    ready = false,
  },
  {
    name = "a slash-command choice without an input box above it",
    lines = { "⏺ an answer", RULE, "  ❯ /clear   Start a new session" },
    ready = false,
  },
  {
    name = "a multi-line input with a ❯ on a later line",
    lines = { RULE, "❯\194\160ls output:", "  prompt ❯ here", RULE, "  ⏵⏵ auto mode on" },
    ready = true,
  },
  {
    name = "a multi-line input with a ❯ in the first column of a later line",
    lines = { RULE, "❯\194\160first", "❯ second", RULE },
    ready = true,
  },
  {
    name = "a multi-line input with a later line like a menu choice",
    lines = { RULE, "❯\194\160first", "  ❯ /clear   Start a new session", RULE },
    ready = true,
  },
  {
    name = "shell mode with a ❯ on a later line",
    lines = { RULE, "!\194\160echo a", "  prompt ❯ here", RULE },
    ready = true,
  },
  {
    name = "a multi-line input with a ❯ on a later line, below an older box",
    lines = { RULE, "❯ old text", RULE, "⏺ an answer", RULE, "❯\194\160first", "  a ❯ b", RULE },
    ready = true,
  },
  {
    name = "an old box with a ❯ on a later line above a permission dialog",
    lines = {
      RULE,
      "❯ first",
      "  a ❯ b",
      RULE,
      "⏺ Bash(touch created.txt)",
      RULE,
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. No",
    },
    ready = false,
  },
  {
    name = "a dialog with a rule below it, right below an old input box",
    lines = { RULE, "❯ ", RULE, " Do you want to proceed?", " ❯ 1. Yes", "   2. No", RULE },
    ready = false,
  },
  {
    name = "an old box with a ❯ on a later line above a dialog without a choice marker",
    lines = { RULE, "❯ first", "  a ❯ b", RULE, RULE, " Press Enter to continue" },
    ready = false,
  },
  {
    name = "an old box with a ❯ on a later line above a dialog's text without a rule",
    lines = { RULE, "❯ first", "  a ❯ b", RULE, " Press Enter to continue" },
    ready = false,
  },
  {
    name = "an old box with a ❯ on a later line above newer output",
    lines = {
      RULE,
      "❯ first",
      "  a ❯ b",
      RULE,
      "⏺ Bash(x)",
      RULE,
      " Do you want to proceed?",
      " Yes / No",
    },
    ready = false,
  },
  {
    name = "a multi-line input with a ❯ on a later line and a notice below the footer",
    lines = {
      RULE,
      "❯\194\160first",
      "  a ❯ b",
      RULE,
      "  ⏵⏵ auto mode on (shift+tab to cycle)",
      string.rep(" ", 70) .. "ctrl+y to paste deleted text",
      "",
    },
    ready = true,
  },
  {
    name = "an old box with a ❯ on a later line above an indented result",
    lines = { RULE, "❯ first", "  a ❯ b", RULE, "  ⎿  Interrupted · What should Claude do instead?" },
    ready = false,
  },
  {
    name = "an old box with a ❯ on a later line above newer output in the first column",
    lines = { RULE, "❯ first", "  a ❯ b", RULE, "⏺ Done." },
    ready = false,
  },
  {
    name = "an old box with a ❯ on a later line above a spinner",
    lines = { RULE, "❯ first", "  a ❯ b", RULE, "", "✻ Thinking…" },
    ready = false,
  },
  {
    name = "a multi-line input with a ❯ on a later line, in shell mode's footer",
    lines = { RULE, "!\194\160echo a", "  a ❯ b", RULE, "  ! for shell mode" },
    ready = true,
  },
  {
    name = "a multi-line input with a ❯ on a later line, the shortcuts hint and a notice",
    lines = { RULE, "❯\194\160first", "  a ❯ b", RULE, "  ? for shortcuts", "  ⚠ Transcript saving is off" },
    ready = true,
  },
  {
    name = "a multi-line input with a ❯ on a later line, manual mode",
    lines = { RULE, "❯\194\160first", "  a ❯ b", RULE, "  ⏸ manual mode on · esc to interrupt" },
    ready = true,
  },
  {
    name = "a multi-line slash command with a ❯ on a later line and its menu open",
    lines = {
      RULE,
      "❯\194\160/clear",
      "  a ❯ b",
      RULE,
      "  ❯ /clear   Start a new session",
      "    /compact   Free up context",
    },
    ready = true,
  },
  {
    name = "a multi-line input with a ❯ on a later line and a status line",
    lines = { RULE, "❯\194\160first", "  a ❯ b", RULE, "  [Opus] ~/dev/duet main", "  ⏵⏵ auto mode on" },
    ready = true,
  },
  {
    name = "a multi-line input with a ❯ on a later line and an exit hint",
    lines = { RULE, "❯\194\160first", "  a ❯ b", RULE, "  Press Ctrl-C again to exit" },
    ready = true,
  },
  {
    name = "a box with a ❯ on a later line, cut off at the bottom",
    lines = { RULE, "❯\194\160first", "  a ❯ b" },
    ready = false,
  },
  -- An old input box whose closing rule has newer content below it, with no `❯` after it.
  {
    name = "an old input box above a dialog without a choice marker",
    lines = { RULE, "❯ old", RULE, RULE, " Press Enter to continue" },
    ready = false,
  },
  {
    name = "an old input box above a dialog's text without a rule",
    lines = { RULE, "❯ old", RULE, " Press Enter to continue" },
    ready = false,
  },
  {
    name = "an old input box above an indented result",
    lines = { RULE, "❯ first", RULE, "  ⎿  Interrupted · What should Claude do instead?" },
    ready = false,
  },
  {
    name = "an old input box above newer output in the first column",
    lines = { RULE, "❯ first", RULE, "⏺ Done." },
    ready = false,
  },
  {
    name = "an old input box above a spinner",
    lines = { RULE, "❯ first", RULE, "", "✻ Thinking…" },
    ready = false,
  },
  {
    name = "an old shell prompt above a dialog without a choice marker",
    lines = { RULE, "! ls", RULE, RULE, " Press Enter to continue" },
    ready = false,
  },
  {
    name = "an old input box above newer output and a dialog without a choice marker",
    lines = { RULE, "❯ old", RULE, "⏺ Bash(x)", RULE, " Do you want to proceed?", " Yes / No" },
    ready = false,
  },
  {
    name = "an old input box above a dialog without a choice marker, then a blank line",
    lines = { RULE, "❯ old", RULE, RULE, " Press Enter to continue", "" },
    ready = false,
  },
  {
    name = "an old box without a closing rule above a dialog's text",
    lines = { RULE, "❯ old", " Press Enter to continue" },
    ready = false,
  },
  {
    name = "an old box without a closing rule above newer output",
    lines = { RULE, "❯ old", "⏺ Done." },
    ready = false,
  },
  {
    name = "a multi-line input cut off at the bottom",
    lines = { RULE, "❯\194\160line one", "  line two", "" },
    ready = true,
  },
  -- Footer rows below the live box, as Claude Code 2.1.330 draws them.
  {
    name = "the live box with a status line and the mode footer",
    lines = { RULE, "❯\194\160", RULE, "  [Opus] ~/dev/duet main", "  ⏵⏵ auto mode on (shift+tab to cycle)" },
    ready = true,
  },
  {
    name = "the live box with the shortcuts hint and a notice",
    lines = { RULE, "❯\194\160", RULE, "  ? for shortcuts", "  ⚠ Transcript saving is off", "" },
    ready = true,
  },
  {
    name = "the live box with the file picker open",
    lines = { RULE, "❯\194\160@a", RULE, "  @ a.lua", "    b/a.txt" },
    ready = true,
  },
  {
    name = "the live box with a right-aligned hint",
    lines = { RULE, "❯\194\160", RULE, "  ⏸ manual mode on", string.rep(" ", 70) .. "ctrl+y to paste deleted text" },
    ready = true,
  },
}

T["format_ref()"] = MiniTest.new_set({
  parametrize = {
    { "file", { path = "src/a.lua" }, "@src/a.lua" },
    { "one line", { path = "src/a.lua", range = { 7, 7 } }, "@src/a.lua (line 7)" },
    { "lines", { path = "src/a.lua", range = { 10, 20 } }, "@src/a.lua (lines 10-20)" },
    { "absolute path", { path = "/tmp/x.lua" }, "@/tmp/x.lua" },
    { "path with a space", { path = "docs/my notes.md" }, "docs/my notes.md" },
    { "path with a space and lines", { path = "docs/my notes.md", range = { 3, 5 } }, "docs/my notes.md (lines 3-5)" },
    { "path with a tab", { path = "a\tb.lua", range = { 1, 1 } }, "a\tb.lua (line 1)" },
  },
})

T["format_ref()"]["works"] = function(_, args, want)
  eq(claude():format_ref(args.path, args.range), want)
end

for _, case in ipairs(ready_cases) do
  T["is_ready()"][case.name] = function()
    eq(claude():is_ready(case.lines), case.ready)
  end
end

T["read_input()"] = MiniTest.new_set()

local NBSP = "\194\160"
local R80 = string.rep("─", 80)

local input_cases = {
  { name = "the startup placeholder", lines = READY, input = '❯ Try "how do I log an error?"' },
  {
    name = "typed text, trailing spaces removed",
    lines = { R80, "❯" .. NBSP .. "fix the bug   ", R80, "  ⏵⏵ auto mode on" },
    input = "❯" .. NBSP .. "fix the bug",
  },
  { name = "an empty input", lines = { R80, "❯" .. NBSP, R80 }, input = "❯" .. NBSP },
  {
    name = "a multi-line input",
    lines = { R80, "❯" .. NBSP .. "line one", "  line two", R80, "  ? for shortcuts" },
    input = "❯" .. NBSP .. "line one\n  line two",
  },
  {
    name = "a slash command with its menu open",
    lines = {
      R80,
      "❯" .. NBSP .. "/copy",
      R80,
      "  ❯ /copy      Copy Claude's last response to the clipboard",
      "    /compact   Clear conversation history but keep a summary",
    },
    input = "❯" .. NBSP .. "/copy",
  },
  {
    name = "the live box, not an older one above it",
    lines = { R80, "❯ old text", R80, "⏺ an answer", R80, "❯" .. NBSP, R80 },
    input = "❯" .. NBSP,
  },
  {
    name = "a box cut off at the bottom",
    lines = { R80, "❯" .. NBSP .. "line one", "  line two" },
    input = "❯" .. NBSP .. "line one\n  line two",
  },
  { name = "shell mode", lines = { R80, "!" .. NBSP .. "ls", R80 }, input = "!" .. NBSP .. "ls" },
  {
    name = "shell mode below an older box",
    lines = { R80, "❯ old text", R80, "⏺ an answer", R80, "!" .. NBSP .. "ls", R80 },
    input = "!" .. NBSP .. "ls",
  },
  {
    name = "a multi-line input with a ❯ on a later line",
    lines = { R80, "❯" .. NBSP .. "ls output:", "  prompt ❯ here", R80, "  ⏵⏵ auto mode on" },
    input = "❯" .. NBSP .. "ls output:\n  prompt ❯ here",
  },
  { name = "no input box", lines = vim.list_slice(READY, 1, 3), input = vim.NIL },
  {
    name = "a permission dialog",
    lines = {
      R80,
      "❯ ",
      R80,
      "⏺ Bash(touch created.txt)",
      R80,
      " Do you want to proceed?",
      " ❯ 1. Yes",
      "   2. No",
    },
    input = vim.NIL,
  },
  {
    name = "an old box above a dialog without a choice marker",
    lines = { R80, "❯ old", R80, R80, " Press Enter to continue" },
    input = vim.NIL,
  },
}

for _, case in ipairs(input_cases) do
  T["read_input()"][case.name] = function()
    local got = claude():read_input(case.lines)
    eq(got == nil and vim.NIL or got, case.input)
  end
end

return T
