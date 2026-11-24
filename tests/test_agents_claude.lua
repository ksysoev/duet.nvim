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
  { name = "prompt marker without a rule", lines = { "some output", "❯ text" }, ready = false },
}

for _, case in ipairs(ready_cases) do
  T["is_ready()"][case.name] = function()
    eq(claude():is_ready(case.lines), case.ready)
  end
end

return T
