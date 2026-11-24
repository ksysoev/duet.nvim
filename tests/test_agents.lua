local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local capture

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.reset_modules()
      capture = h.capture_notify()
    end,
    post_case = function()
      capture.restore()
    end,
  },
})

local function agents()
  return require("duet.agents")
end

local function fake(name, extra)
  return vim.tbl_extend("force", {
    name = name,
    cmd = { "fake-" .. name },
    capabilities = { mcp = false, plan_hook = false, system_prompt = false },
    launch = function(self, _)
      return { argv = vim.list_extend(vim.deepcopy(self.cmd), self.args or {}), env = self.env or {}, files = {} }
    end,
  }, extra or {})
end

local SPEC = { cwd = "/w", session_id = "s1", run_dir = "/run/duet/s1" }

T["get()"] = MiniTest.new_set()

T["get()"]["returns the default agent"] = function()
  local agent = agents().get()
  eq(agent.name, "claude")
  eq(agent.cmd, { "claude" })
  eq(agent.capabilities, { mcp = true, plan_hook = true, system_prompt = true })
end

T["get()"]["follows the agent option"] = function()
  agents().register(fake("other"))
  require("duet.config").setup({ agent = "other" })
  eq(agents().get().name, "other")
end

T["get()"]["reports an unknown agent"] = function()
  local agent, err = agents().get("nope")
  eq(agent, nil)
  eq(err, "agents: unknown agent 'nope' (available: claude)")
end

T["get()"]["returns independent instances"] = function()
  local a = agents().get("claude")
  a.cmd[1] = "changed"
  a.capabilities.mcp = false
  local b = agents().get("claude")
  eq(b.cmd, { "claude" })
  eq(b.capabilities.mcp, true)
  eq(require("duet.agents.claude").cmd, { "claude" })
end

T["overrides"] = MiniTest.new_set()

local override_cases = {
  {
    name = "no overrides",
    opts = {},
    argv = { "claude" },
    env = {},
  },
  {
    name = "cmd replaces the command",
    opts = { cmd = { "/opt/bin/claude", "--verbose" } },
    argv = { "/opt/bin/claude", "--verbose" },
    env = {},
  },
  {
    name = "args are appended after cmd",
    opts = { args = { "--model", "opus" } },
    argv = { "claude", "--model", "opus" },
    env = {},
  },
  {
    name = "env is added",
    opts = { env = { FOO = "1" } },
    argv = { "claude" },
    env = { FOO = "1" },
  },
  {
    name = "all together",
    opts = { cmd = { "c" }, args = { "-a" }, env = { A = "x" } },
    argv = { "c", "-a" },
    env = { A = "x" },
  },
}

for _, case in ipairs(override_cases) do
  T["overrides"][case.name] = function()
    eq(require("duet.config").setup({ agents = { claude = case.opts } }), true)
    local plan = agents().get("claude"):launch(SPEC)
    eq(plan.argv, case.argv)
    eq(plan.env, case.env)
  end
end

T["overrides"]["user env wins over the adapter's env"] = function()
  require("duet.config").setup({ agents = { claude = { env = { MCP_TOOL_TIMEOUT = "5" } } } })
  local plan = agents().get("claude"):launch(vim.tbl_extend("force", SPEC, { tool_timeout_ms = 1000 }))
  eq(plan.env, { MCP_TOOL_TIMEOUT = "5" })
end

T["overrides"]["are read when get() is called"] = function()
  require("duet.config").setup({ agents = { claude = { cmd = { "first" } } } })
  eq(agents().get("claude").cmd, { "first" })
  require("duet.config").setup({ agents = { claude = { cmd = { "second" } } } })
  eq(agents().get("claude").cmd, { "second" })
end

T["overrides"]["apply to registered adapters"] = function()
  agents().register(fake("other", { env = { BASE = "1", KEEP = "1" } }))
  require("duet.config").setup({ agents = { other = { args = { "-x" }, env = { BASE = "2" } } } })
  local plan = agents().get("other"):launch(SPEC)
  eq(plan.argv, { "fake-other", "-x" })
  eq(plan.env, { BASE = "2", KEEP = "1" })
end

T["register()"] = MiniTest.new_set()

T["register()"]["adds an adapter"] = function()
  agents().register(fake("zeta"))
  agents().register(fake("alpha"))
  eq(agents().list(), { "alpha", "claude", "zeta" })
  eq(agents().complete_names("a"), { "alpha" })
  eq(agents().get("zeta").cmd, { "fake-zeta" })
end

T["register()"]["replaces a built-in"] = function()
  agents().register(fake("claude"))
  eq(agents().get("claude").cmd, { "fake-claude" })
  eq(agents().list(), { "claude" })
end

local bad_adapters = {
  { name = "not a table", adapter = "x" },
  { name = "missing name", adapter = { cmd = { "x" }, capabilities = {}, launch = function() end } },
  { name = "empty name", adapter = fake("") },
  { name = "empty cmd", adapter = fake("x", { cmd = {} }) },
  { name = "cmd is a string", adapter = fake("x", { cmd = "x" }) },
  { name = "missing launch", adapter = fake("x", { launch = 1 }) },
  { name = "is_ready not a function", adapter = fake("x", { is_ready = true }) },
}

for _, case in ipairs(bad_adapters) do
  T["register()"]["rejects " .. case.name] = function()
    MiniTest.expect.error(function()
      agents().register(case.adapter)
    end)
  end
end

return T
