---@brief Agent adapter registry and user overrides.
--- Adapters describe how to launch an agent CLI and what it supports. The core only talks
--- to adapters, and branches on `capabilities`, never on the agent's name. Built-in
--- adapters load lazily the first time `get()` asks for them. See |duet-agents|.

local M = {}

---@class duet.LaunchSpec
---@field cwd string working directory of the agent
---@field session_id string duet session id
---@field run_dir string absolute per-session directory; every file in the plan must live in it
---@field mcp? { name: string, command: string[], env: table<string, string> } bridge server to attach
---@field hooks? { plan_review?: duet.HookSpec } hook commands the agent should run
---@field system_prompt? string text added to the agent's system prompt
---@field tool_timeout_ms? integer how long the agent waits for a tool call

---@class duet.HookSpec
---@field command string[] argv of the hook command
---@field timeout_s? integer how long the agent waits for the hook, in seconds

---@class duet.LaunchFile
---@field path string absolute path inside `spec.run_dir`
---@field content string

---@class duet.LaunchPlan
---@field argv string[]
---@field env table<string, string>
---@field files duet.LaunchFile[] written by the core (mode 0600) before spawning

---@class duet.Capabilities
---@field mcp boolean the agent can attach duet's MCP server
---@field plan_hook boolean the agent can run a hook before it leaves plan mode
---@field system_prompt boolean the agent accepts extra system prompt text

---@class duet.Agent
---@field name string
---@field cmd string[] command line, before any arguments duet adds
---@field args? string[] extra arguments, after `cmd` (from `agents.<name>.args`)
---@field env? table<string, string> extra environment (from `agents.<name>.env`)
---@field capabilities duet.Capabilities
---@field launch fun(self: duet.Agent, spec: duet.LaunchSpec): duet.LaunchPlan pure: no I/O
---@field is_ready? fun(self: duet.Agent, lines: string[]): boolean the TUI accepts input
---@field format_ref? fun(self: duet.Agent, path: string, range?: integer[]): string file reference
---@field health? fun(self: duet.Agent) extra :checkhealth reports (vim.health.*)

---Built-in adapters, loaded on first use.
---@type table<string, string>
local builtin = {
  claude = "duet.agents.claude",
}

---@type table<string, duet.Agent>
local registry = {}

local function is_string_list(v)
  if type(v) ~= "table" or not vim.islist(v) then
    return false
  end
  for _, item in ipairs(v) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

---Register an adapter, replacing any adapter with the same name (built-ins included).
---Throws on a malformed adapter: that is a programmer error.
---@param adapter duet.Agent
function M.register(adapter)
  vim.validate("adapter", adapter, "table")
  vim.validate("adapter.name", adapter.name, "string")
  vim.validate("adapter.cmd", adapter.cmd, function(v)
    return is_string_list(v) and #v > 0
  end, "non-empty list of strings")
  vim.validate("adapter.capabilities", adapter.capabilities, "table")
  vim.validate("adapter.launch", adapter.launch, "function")
  vim.validate("adapter.is_ready", adapter.is_ready, "function", true)
  vim.validate("adapter.format_ref", adapter.format_ref, "function", true)
  vim.validate("adapter.health", adapter.health, "function", true)
  if adapter.name == "" then
    error("agents: adapter name must not be empty", 2)
  end
  registry[adapter.name] = adapter
end

---Find the base adapter for `name`, loading a built-in on first use.
---@param name string
---@return duet.Agent|nil
---@return string|nil err
local function base(name)
  if registry[name] then
    return registry[name]
  end
  local module = builtin[name]
  if not module then
    return nil, ("agents: unknown agent '%s' (available: %s)"):format(name, table.concat(M.list(), ", "))
  end
  local ok, adapter = pcall(require, module)
  if not ok then
    return nil, ("agents: failed to load '%s': %s"):format(name, adapter)
  end
  M.register(adapter)
  return adapter
end

---Get an adapter with the user's overrides from `agents.<name>` applied.
---Each call returns a new instance built from the current config, so changing the
---instance does not affect the adapter or later calls.
---@param name? string agent name (default: the `agent` option)
---@return duet.Agent|nil agent
---@return string|nil err
function M.get(name)
  local config = require("duet.config").get()
  name = name or config.agent
  local adapter, err = base(name)
  if not adapter then
    return nil, err
  end
  local override = config.agents[name] or {}
  local agent = setmetatable({}, { __index = adapter })
  agent.cmd = vim.deepcopy(override.cmd or adapter.cmd)
  agent.args = vim.deepcopy(override.args or adapter.args or {})
  agent.env = vim.tbl_extend("force", vim.deepcopy(adapter.env or {}), vim.deepcopy(override.env or {}))
  agent.capabilities = vim.deepcopy(adapter.capabilities)
  return agent
end

---Names of all known adapters (built-in and registered), sorted.
---@return string[]
function M.list()
  local names = {}
  for name in pairs(builtin) do
    names[name] = true
  end
  for name in pairs(registry) do
    names[name] = true
  end
  local list = vim.tbl_keys(names)
  table.sort(list)
  return list
end

---Adapter names that start with `arglead`, for command completion.
---@param arglead string
---@return string[]
function M.complete_names(arglead)
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arglead)
  end, M.list())
end

local FEATURES = {
  { key = "mcp", desc = "agent → editor tools (MCP)" },
  { key = "plan_hook", desc = "plan review" },
  { key = "system_prompt", desc = "system prompt" },
}

---Report one agent: its binary, its own checks and its capabilities.
---@param name string
---@param is_default boolean
local function check_agent(name, is_default)
  local agent, err = M.get(name)
  if not agent then
    -- An unknown default agent breaks :Duet; overrides for an unknown agent are only unused.
    local report = is_default and vim.health.error or vim.health.warn
    report(err --[[@as string]])
    return
  end
  local label = is_default and (name .. " (default)") or name
  local bin = agent.cmd[1]
  if vim.fn.executable(bin) == 1 then
    vim.health.ok(("%s: `%s` found on PATH"):format(label, bin))
  else
    vim.health.error(
      ("%s: `%s` not found on PATH"):format(label, bin),
      { ("Install it, or set `agents.%s.cmd` to the full path"):format(name) }
    )
    return
  end
  if agent.health then
    local ok, msg = pcall(agent.health, agent)
    if not ok then
      vim.health.error(("%s: check failed: %s"):format(name, msg))
    end
  end
  local missing = {}
  for _, feature in ipairs(FEATURES) do
    if not agent.capabilities[feature.key] then
      missing[#missing + 1] = feature.desc
    end
  end
  if #missing > 0 then
    vim.health.info(("%s: not supported, so disabled: %s"):format(name, table.concat(missing, ", ")))
  end
end

---Report on the default agent and every agent configured under `agents`.
---Used by :checkhealth duet.
function M.health()
  local config = require("duet.config").get()
  local names = { config.agent }
  local configured = vim.tbl_keys(config.agents)
  table.sort(configured)
  for _, name in ipairs(configured) do
    if name ~= config.agent then
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(names) do
    check_agent(name, name == config.agent)
  end
end

return M
