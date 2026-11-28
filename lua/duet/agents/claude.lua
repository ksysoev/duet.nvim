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

---The width of a horizontal rule: the number of "─" characters in a line made only of
---them (then optional spaces), or 0 if `line` is not a rule. (A Lua pattern can't repeat
---"─" because it is several bytes long.)
---@param line string
---@return integer
local function rule_width(line)
  local body = line:gsub("%s+$", "")
  local rest, width = body:gsub("─", "")
  return rest == "" and width or 0
end

---Whether `line` is a horizontal rule (see rule_width).
---@param line string
---@return boolean
local function is_rule(line)
  return rule_width(line) > 0
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

---Whether `line` can be a row below the live input box: a blank line, or a row indented
---by two spaces or more (the footer such as `  ⏵⏵ auto mode on`, notices, a status line,
---the slash-command menu, right-aligned hints). Newer content starts further left: output
---(`⏺ …`) and spinners in the first column, dialog text and choices after one space, rules.
---A tool result (`  ⎿ …`) is indented like the footer but only comes below newer output.
---@param line string
---@return boolean
local function is_footer_row(line)
  if line:match("^%s*$") then
    return true
  end
  return line:match("^  ") ~= nil and not line:match("^%s*⎿")
end

---Whether `line` starts with a `❯`, after any spaces and a dialog's vertical borders
---(`  ❯ 1. Yes`, `  │ ❯ Yes │`): where a dialog marks its selected choice.
---@param line string
---@return boolean
local function starts_with_marker(line)
  local rest = vim.trim(line)
  while vim.startswith(rest, "│") or vim.startswith(rest, "┃") do
    rest = vim.trim(rest:sub(#"│" + 1))
  end
  return vim.startswith(rest, "❯")
end

---Whether an input box's prompt line holds a slash command. In a Neovim terminal, Claude
---Code puts a no-break space after the `❯` of the live input box (a plain space in the
---transcript and the menu).
---@param line string
---@return boolean
local function holds_command(line)
  return vim.startswith(line, "❯ /") or vim.startswith(line, "❯" .. NBSP .. "/")
end

---Whether only footer rows (see is_footer_row) follow the closing rule at `close` of the
---input box whose prompt line is `prompt`. A row that starts with a `❯` (see
---starts_with_marker) marks a dialog's choice, unless it is the selected entry of the
---slash-command menu (`  ❯ /clear   Start a new session…`, indented by two spaces) below a
---box that holds a slash command. A `❯` after other text, such as a starship-style status
---line (`  ~/dev ❯ main`), is not a choice.
---@param lines string[]
---@param prompt string the box's prompt line
---@param close integer
---@return boolean
local function only_footer_below(lines, prompt, close)
  for k = close + 1, #lines do
    local line = lines[k]
    if not is_footer_row(line) then
      return false
    elseif starts_with_marker(line) and not (line:match("^  ❯ /%S") and holds_command(prompt)) then
      return false
    end
  end
  return true
end

---The live input box at the bottom of the screen: the index of its prompt line (see
---is_prompt) and of its closing rule. The box is found from the bottom: its closing rule
---is the last rule on screen, with only footer rows below it (see only_footer_below), and
---its top rule is the nearest rule above with the same width, with the prompt line right
---below it. The lines between are the user's input, so a `❯` there (a pasted shell
---prompt) or a narrower rule (pasted box-drawing text or Claude Code output) is just text.
---An older box left above a dialog or newer output doesn't count: the dialog's rule or the
---output comes below its closing rule. Dialogs (folder trust, permission prompts) replace
---the input box, so a rule closing a dialog has no prompt line below its top rule.
---
---A box cut off at the bottom has no closing rule: its prompt line sits right below the
---last rule, and closing is nil. It counts only if its later lines are footer rows (the
---rest of a multi-line input is indented by two spaces) that don't start with a `❯` (see
---starts_with_marker), as such a row can't be told from a dialog's choice. A `❯` after
---other text (`  a ❯ b`) is the user's input. nil if there is no live box.
---@param lines string[]
---@return integer|nil prompt
---@return integer|nil closing
local function live_box(lines)
  local close
  for i = #lines, 1, -1 do
    if is_rule(lines[i]) then
      close = i
      break
    end
  end
  if not close then
    return nil
  end
  if lines[close + 1] and is_prompt(lines[close + 1]) then
    for k = close + 2, #lines do
      if not is_footer_row(lines[k]) or starts_with_marker(lines[k]) then
        return nil
      end
    end
    return close + 1, nil
  end
  local width = rule_width(lines[close])
  for i = close - 1, 1, -1 do
    if rule_width(lines[i]) == width then
      local prompt = i + 1
      if prompt < close and is_prompt(lines[prompt]) and only_footer_below(lines, lines[prompt], close) then
        return prompt, close
      end
      return nil
    end
  end
  return nil
end

---Whether the TUI shows its input prompt, not a dialog (see live_box).
---@param lines string[] terminal buffer lines
---@return boolean
function M:is_ready(lines)
  return live_box(lines) ~= nil
end

---The input box's lines as shown, from its prompt line to the line above its closing rule
---(or the last line, if the box is cut off), with trailing spaces removed: the typed text,
---a placeholder such as `❯ Try "…"`, or a summary such as `[Pasted text #1 +20 lines]`.
---nil if no input box is on screen (see live_box).
---@param lines string[] terminal buffer lines
---@return string|nil
function M:read_input(lines)
  local first, close = live_box(lines)
  if not first then
    return nil
  end
  local rows = {}
  for i = first, (close or #lines + 1) - 1 do
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
