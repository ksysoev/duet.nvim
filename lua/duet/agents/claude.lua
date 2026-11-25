---@brief Claude Code adapter.
--- Maps a duet.LaunchSpec to Claude Code's command line. Verified against Claude Code
--- 2.1.330 and https://code.claude.com/docs/en/cli-reference, …/mcp, …/hooks, …/settings:
--- - MCP server: `--mcp-config <file>` with `{ mcpServers = { <name> = { type = "stdio", … } } }`.
---   The flag takes several values, so duet's flags come after the user's `args`.
--- - Hooks: `--settings <file>`. Its hooks merge with the user's own hooks.
---   A hook `timeout` is in seconds.
--- - System prompt: `--append-system-prompt <text>`.
--- - Tool timeout: `MCP_TOOL_TIMEOUT` in milliseconds.
--- - File references: `@path` (relative or absolute) includes the file in the prompt
---   (https://code.claude.com/docs/en/common-workflows). The docs give no form for a line
---   range, so the lines are named in words after the reference, and no way to quote a
---   path, so a path with whitespace is written without the `@`.

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

---Refer to a file in a prompt: `@path`, `@path (line 10)` or `@path (lines 10-20)`. A path
---with whitespace gets no `@`: the mention would end at the first space and name a file
---that doesn't exist, while a plain path still tells Claude which file to read.
---@param path string relative to the session root
---@param range? integer[] `{ start_line, end_line }`
---@return string
function M:format_ref(path, range)
  local ref = path:find("%s") and path or ("@" .. path)
  if not range then
    return ref
  end
  if range[1] == range[2] then
    return ("%s (line %d)"):format(ref, range[1])
  end
  return ("%s (lines %d-%d)"):format(ref, range[1], range[2])
end

---Whether `line` is a horizontal rule: only "─" characters, then optional spaces.
---(A Lua pattern can't repeat "─" because it is several bytes long.)
---@param line string
---@return boolean
local function is_rule(line)
  local body = line:gsub("%s+$", "")
  return body ~= "" and body:gsub("─", "") == ""
end

-- A no-break space (U+00A0): Claude Code puts one after the shell-mode `!`.
local NBSP = "\194\160"

---Whether `line` is the first line of the input box: `❯` (or `!` in shell mode) in the
---first column. A `❯` before a number is a menu choice.
---@param line string
---@return boolean
local function is_prompt(line)
  if line:match("^❯") then
    return not line:match("^❯%s*%d+%.")
  end
  return line == "!" or line:match("^!%s") ~= nil or vim.startswith(line, "!" .. NBSP)
end

---Whether the TUI shows its input prompt: a prompt line (see is_prompt) right below a
---horizontal rule. Dialogs (folder trust, permission prompts) replace the input box and
---mark their choice with an indented `❯`, so only a prompt at or below the last `❯` on
---screen counts: an older frame left in the scrollback above a dialog doesn't.
---@param lines string[] terminal buffer lines
---@return boolean
function M:is_ready(lines)
  local last = 1
  for i = #lines, 1, -1 do
    if lines[i]:find("❯", 1, true) then
      last = i
      break
    end
  end
  for i = math.max(2, last), #lines do
    if is_prompt(lines[i]) and is_rule(lines[i - 1]) then
      return true
    end
  end
  return false
end

---Report the CLI version. Runs the whole `cmd` (so wrappers such as `npx …` or
---`env FOO=1 claude` report the agent's version, not the wrapper's) plus `--version`,
---with a short timeout. The user's `args` are left out: they don't affect the version.
function M:health()
  local argv = vim.list_extend(vim.deepcopy(self.cmd), { "--version" })
  local label = shell_join(argv)
  local ok, result = pcall(function()
    return vim.system(argv, { text = true }):wait(3000)
  end)
  if not ok then
    vim.health.warn(("%s failed: %s"):format(label, tostring(result)))
  elseif result.code ~= 0 then
    local detail = vim.trim(result.stderr or "")
    vim.health.warn(("%s exited with %d%s"):format(label, result.code, detail ~= "" and (": " .. detail) or ""))
  else
    vim.health.ok("claude version: " .. vim.trim(result.stdout or ""))
  end
end

return M
