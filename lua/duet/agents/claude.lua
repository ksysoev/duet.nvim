---@brief Claude Code adapter.
--- Maps a duet.LaunchSpec to Claude Code's command line. Verified against Claude Code
--- 2.1.330 and https://code.claude.com/docs/en/cli-reference, …/mcp, …/hooks, …/settings:
--- - MCP server: `--mcp-config <file>` with `{ mcpServers = { <name> = { type = "stdio", … } } }`.
---   The flag takes several values, so duet's flags come after the user's `args`.
--- - Hooks: `--settings <file>`. Its hooks merge with the user's own hooks.
---   A hook `timeout` is in seconds.
--- - System prompt: `--append-system-prompt <text>`.
--- - Tool timeout: `MCP_TOOL_TIMEOUT` in milliseconds.

local M = {}

M.name = "claude"
M.cmd = { "claude" }
M.capabilities = { mcp = true, plan_hook = true, system_prompt = true }

-- Claude's default hook timeout is 600 s; a plan review can take longer.
M.DEFAULT_HOOK_TIMEOUT_S = 3600

---Quote a word for a POSIX shell. Claude runs a hook `command` string with `sh -c`.
---@param word string
---@return string
local function shell_quote(word)
  if word:match("^[%w%%%+,%-%./:=@_]+$") then
    return word
  end
  return "'" .. word:gsub("'", [['\'']]) .. "'"
end

---@param argv string[]
---@return string
local function shell_join(argv)
  return table.concat(vim.tbl_map(shell_quote, argv), " ")
end

---A JSON object, even when empty (an empty Lua table encodes as `[]`).
---@param t table<string, string>|nil
---@return table
local function object(t)
  if t == nil or next(t) == nil then
    return vim.empty_dict()
  end
  return t
end

---@param mcp { name: string, command: string[], env: table<string, string> }
---@return string
local function mcp_config(mcp)
  return vim.json.encode({
    mcpServers = {
      [mcp.name] = {
        type = "stdio",
        command = mcp.command[1],
        args = vim.list_slice(mcp.command, 2),
        env = object(mcp.env),
      },
    },
  })
end

---@param hook duet.HookSpec
---@return string
local function settings(hook)
  return vim.json.encode({
    hooks = {
      PreToolUse = {
        {
          matcher = "ExitPlanMode",
          hooks = {
            {
              type = "command",
              command = shell_join(hook.command),
              timeout = hook.timeout_s or M.DEFAULT_HOOK_TIMEOUT_S,
            },
          },
        },
      },
    },
  })
end

---Build the command line, environment and files for a session. Pure: no I/O.
---@param spec duet.LaunchSpec
---@return duet.LaunchPlan
function M:launch(spec)
  vim.validate("spec", spec, "table")
  vim.validate("spec.run_dir", spec.run_dir, "string")
  local argv = vim.list_extend(vim.deepcopy(self.cmd), vim.deepcopy(self.args or {}))
  local env = {}
  local files = {}

  local function add_file(name, content)
    local path = vim.fs.joinpath(spec.run_dir, name)
    files[#files + 1] = { path = path, content = content }
    return path
  end

  if spec.mcp then
    vim.list_extend(argv, { "--mcp-config", add_file("mcp.json", mcp_config(spec.mcp)) })
  end
  local plan_review = spec.hooks and spec.hooks.plan_review
  if plan_review then
    vim.list_extend(argv, { "--settings", add_file("settings.json", settings(plan_review)) })
  end
  if spec.system_prompt then
    vim.list_extend(argv, { "--append-system-prompt", spec.system_prompt })
  end
  if spec.tool_timeout_ms then
    env.MCP_TOOL_TIMEOUT = tostring(spec.tool_timeout_ms)
  end

  return {
    argv = argv,
    env = vim.tbl_extend("force", env, self.env or {}),
    files = files,
  }
end

---Whether `line` is a horizontal rule: only "─" characters, then optional spaces.
---(A Lua pattern can't repeat "─" because it is several bytes long.)
---@param line string
---@return boolean
local function is_rule(line)
  local body = line:gsub("%s+$", "")
  return body ~= "" and body:gsub("─", "") == ""
end

---Whether the TUI shows its input prompt: a `❯` line right below a horizontal rule.
---Menus (such as the folder trust dialog) also use `❯`, but inside a box and before a
---numbered choice, so they don't match.
---@param lines string[] terminal buffer lines
---@return boolean
function M:is_ready(lines)
  for i = 2, #lines do
    local prev, line = lines[i - 1], lines[i]
    if line:match("^❯") and not line:match("^❯%s*%d+%.") and is_rule(prev) then
      return true
    end
  end
  return false
end

---Report the CLI version. Runs `<cmd> --version` with a short timeout.
function M:health()
  local ok, result = pcall(function()
    return vim.system({ self.cmd[1], "--version" }, { text = true }):wait(3000)
  end)
  if not ok then
    vim.health.warn("claude --version failed: " .. tostring(result))
  elseif result.code ~= 0 then
    local detail = vim.trim(result.stderr or "")
    vim.health.warn(("claude --version exited with %d%s"):format(result.code, detail ~= "" and (": " .. detail) or ""))
  else
    vim.health.ok("claude version: " .. vim.trim(result.stdout or ""))
  end
end

return M
