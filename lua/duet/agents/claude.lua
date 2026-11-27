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
--- - Slash commands: typing `/` opens a menu below the input box, and <Enter> runs its
---   highlighted entry, which is the typed command when the full name is typed (a prefix
---   such as `/co` runs the first match, `/copy`). Arguments after a space close the menu.

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

---Whether `line` is the selected entry of the slash-command menu: `❯` indented by two
---spaces before a command name, e.g. `  ❯ /clear   Start a new session…`. (Dialogs
---indent their choice by one space.)
---@param line string
---@return boolean
local function is_menu_choice(line)
  return line:match("^  ❯ /%S") ~= nil
end

---The prompt line of the input box that the rule at `close` closes: the nearest prompt
---line above it that sits right below a rule, with no rule in between (the lines between
---are the rest of a multi-line input). nil if the rule doesn't close an input box.
---@param lines string[]
---@param close integer
---@return integer|nil
local function box_prompt(lines, close)
  for i = close - 1, 2, -1 do
    if is_rule(lines[i]) then
      return nil
    elseif is_prompt(lines[i]) and is_rule(lines[i - 1]) then
      return i
    end
  end
  return nil
end

---Whether `line` can be a row of the slash-command menu below its selected entry: another
---entry (indented by four spaces), a wrapped description (indented further), or a blank
---line. Claude Code's other output is indented less: `  ⎿ …` results, the `  ⏵⏵ …`
---footer, dialog text.
---@param line string
---@return boolean
local function is_menu_row(line)
  return line:match("^%s*$") ~= nil or line:match("^    ") ~= nil
end

---Whether an input box's prompt line holds a slash command. In a Neovim terminal, Claude
---Code puts a no-break space after the `❯` of the live input box (a plain space in the
---transcript and the menu).
---@param line string
---@return boolean
local function holds_command(line)
  return vim.startswith(line, "❯ /") or vim.startswith(line, "❯" .. NBSP .. "/")
end

---If line `i` is the selected entry of the slash-command menu, the prompt line of the
---input box the menu belongs to. The entry must hang below the box's closing rule (other
---entries or a notice may come between), the box must hold a slash command, and only
---menu rows may follow the entry, so a menu left above newer output doesn't count.
---@param lines string[]
---@param i integer
---@return integer|nil
local function menu_prompt(lines, i)
  if not is_menu_choice(lines[i]) then
    return nil
  end
  for j = i + 1, #lines do
    if not is_menu_row(lines[j]) then
      return nil
    end
  end
  for j = i - 1, 2, -1 do
    if lines[j]:find("❯", 1, true) then
      return nil
    elseif is_rule(lines[j]) then
      local prompt = box_prompt(lines, j)
      return prompt and holds_command(lines[prompt]) and prompt or nil
    end
  end
  return nil
end

---The index of the last line that marks a choice with `❯`, or 1 if none does. Typing `/`
---opens the slash-command menu below the input box, and its selected entry is marked
---like a dialog's choice: the box's prompt counts instead (see menu_prompt).
---@param lines string[]
---@return integer
local function last_marker(lines)
  for i = #lines, 1, -1 do
    if lines[i]:find("❯", 1, true) then
      return menu_prompt(lines, i) or i
    end
  end
  return 1
end

---The first line of the live input box: a prompt line (see is_prompt) right below a
---horizontal rule. Dialogs (folder trust, permission prompts) replace the input box and
---mark their choice with an indented `❯`, so only a prompt at or below the last `❯` on
---screen counts: an older frame left in the scrollback above a dialog doesn't. The
---slash-command menu's `❯` doesn't count (see last_marker). The last such prompt line
---counts: in shell mode the live box starts with `!`, so an older box can sit between
---the last `❯` and it. nil if there is none.
---@param lines string[]
---@return integer|nil
local function live_prompt(lines)
  for i = #lines, math.max(2, last_marker(lines)), -1 do
    if is_prompt(lines[i]) and is_rule(lines[i - 1]) then
      return i
    end
  end
  return nil
end

---Whether the TUI shows its input prompt, not a dialog (see live_prompt).
---@param lines string[] terminal buffer lines
---@return boolean
function M:is_ready(lines)
  return live_prompt(lines) ~= nil
end

---The input box's lines as shown, from its prompt line to the line above its closing rule
---(or the last line, if the box is cut off), with trailing spaces removed: the typed text,
---a placeholder such as `❯ Try "…"`, or a summary such as `[Pasted text #1 +20 lines]`.
---nil if no input box is on screen (see live_prompt).
---@param lines string[] terminal buffer lines
---@return string|nil
function M:read_input(lines)
  local first = live_prompt(lines)
  if not first then
    return nil
  end
  local rows = {}
  for i = first, #lines do
    if i > first and is_rule(lines[i]) then
      break
    end
    rows[#rows + 1] = (lines[i]:gsub("%s+$", ""))
  end
  return table.concat(rows, "\n")
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
