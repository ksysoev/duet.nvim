---@brief Editor context for prompts: a provider registry and a template renderer.
--- A provider turns a captured context (buffer, window, cursor, range) into text for the
--- agent plus structured data, so the same providers serve `{name}` placeholders in sent
--- text and the `get_context` tool. Built-in providers load lazily from
--- `duet.context.providers.*` the first time they are used. See |duet-context|.

local M = {}

-- Most items a list provider (diagnostics, quickfix, buffers) includes; the rest are
-- counted in a "… and N more" line.
M.MAX_ITEMS = 200

---@class duet.Range
---@field start_line integer 1-based, inclusive
---@field end_line integer 1-based, inclusive
---@field mode "line"|"char"|"block"
---@field start_col? integer 1-based byte column ("char" and "block" only)
---@field end_col? integer 1-based byte column, inclusive ("char" and "block" only)

---@class duet.Context
---@field buf integer buffer the context is about
---@field win integer window showing `buf`
---@field cursor integer[] `{ line, col }` in `win` when captured: 1-based line, 0-based byte column
---@field cwd string root that paths are made relative to
---@field agent? duet.Agent adapter whose `format_ref` formats file references
---@field range? duet.Range lines (or region) the command was given

---@class duet.ContextResult
---@field text string rendering for the agent
---@field data table JSON-encodable structured form
---@field block? boolean multi-line text that goes on lines of its own

---@alias duet.ContextProvider fun(ctx: duet.Context): duet.ContextResult|nil

---@class duet.RenderInfo
---@field used string[] registered placeholders in the template, in order of first use
---@field empty string[] those of them that rendered empty

---@class duet.CaptureOpts
---@field range? integer number of range items given to the command (0, 1 or 2)
---@field line1? integer first line of the range
---@field line2? integer last line of the range
---@field win? integer window to capture (default: the current one)
---@field agent? string agent whose references to use (default: the current session's)

---Built-in providers: name → module. Each module returns a table of providers by name.
---@type table<string, string>
local builtin = {
  file = "duet.context.providers.file",
  this = "duet.context.providers.file",
  selection = "duet.context.providers.selection",
  diagnostics = "duet.context.providers.diagnostics",
  diagnostics_all = "duet.context.providers.diagnostics",
  quickfix = "duet.context.providers.quickfix",
  buffers = "duet.context.providers.buffers",
}

---Registered providers. `false` hides a built-in one.
---@type table<string, duet.ContextProvider|false>
local registry = {}

local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_]+$") ~= nil
end

---Register a provider for `{name}`, replacing any provider with that name (built-ins
---included). Throws on a bad name or a non-function: that is a programmer error.
---@param name string letters, digits and `_`
---@param fn duet.ContextProvider returns nil when it has nothing to add
function M.register(name, fn)
  vim.validate("name", name, valid_name, "name of letters, digits and _")
  vim.validate("fn", fn, "function")
  registry[name] = fn
end

---Remove a provider, built-in ones included. `{name}` is then left as typed.
---@param name string
function M.unregister(name)
  if builtin[name] then
    registry[name] = false
  else
    registry[name] = nil
  end
end

---Names of the available providers, sorted.
---@return string[]
function M.names()
  local set = {}
  for name in pairs(builtin) do
    set[name] = true
  end
  for name, fn in pairs(registry) do
    set[name] = fn ~= false or nil
  end
  local names = vim.tbl_keys(set)
  table.sort(names)
  return names
end

---The provider for `name`, loading a built-in on first use.
---@param name string
---@return duet.ContextProvider|nil
---@return string|nil err
local function provider(name)
  local fn = registry[name]
  if fn ~= nil then
    return fn or nil
  end
  local module = builtin[name]
  if not module then
    return nil
  end
  local ok, providers = pcall(require, module)
  if not ok then
    return nil, ("context: failed to load '%s': %s"):format(name, providers)
  end
  return providers[name]
end

-- Capturing ------------------------------------------------------------------

---Whether `buf` holds code the user works on, rather than a terminal, help, a list etc.
---@param buf integer
---@return boolean
local function is_code(buf)
  return vim.bo[buf].buftype == "" and vim.b[buf].duet_session == nil
end

---The window to take context from: `win` when it shows code, else the previous window,
---else the first window showing code in the tab, else `win`.
---@param win integer
---@return integer
local function code_window(win)
  if is_code(vim.api.nvim_win_get_buf(win)) then
    return win
  end
  local candidates = { vim.fn.win_getid(vim.fn.winnr("#")) }
  vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)))
  for _, id in ipairs(candidates) do
    if
      id ~= 0
      and vim.api.nvim_win_is_valid(id)
      and vim.api.nvim_win_get_config(id).relative == ""
      and is_code(vim.api.nvim_win_get_buf(id))
    then
      return id
    end
  end
  return win
end

local VISUAL_MODES = { v = "char", V = "line", ["\22"] = "block" }

---A range from two positions (`{ line, col }`, 1-based), in either order.
---@param a integer[]
---@param b integer[]
---@param mode "line"|"char"|"block"
---@return duet.Range
local function region(a, b, mode)
  if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then
    a, b = b, a
  end
  local range = { start_line = a[1], end_line = b[1], mode = mode }
  if mode == "block" then
    range.start_col, range.end_col = math.min(a[2], b[2]), math.max(a[2], b[2])
  elseif mode == "char" then
    range.start_col, range.end_col = a[2], b[2]
  end
  return range
end

---The range for the command: the visual selection when it matches the range given (so a
---character-wise selection keeps its columns), else the lines given; or, with no range,
---the visual selection when the call comes from visual mode (a `<Cmd>` mapping, Lua).
---@param opts duet.CaptureOpts
---@param mode string mode() when the call came
---@return duet.Range|nil
local function command_range(opts, mode)
  if (opts.range or 0) > 0 and opts.line1 and opts.line2 then
    local vmode = VISUAL_MODES[vim.fn.visualmode()]
    local first, last = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if opts.range == 2 and vmode and vmode ~= "line" and first[2] == opts.line1 and last[2] == opts.line2 then
      return region({ first[2], first[3] }, { last[2], last[3] }, vmode)
    end
    return { start_line = math.min(opts.line1, opts.line2), end_line = math.max(opts.line1, opts.line2), mode = "line" }
  end
  local vmode = VISUAL_MODES[mode]
  if vmode then
    local v, dot = vim.fn.getpos("v"), vim.fn.getpos(".")
    return region({ v[2], v[3] }, { dot[2], dot[3] }, vmode)
  end
  return nil
end

---Capture the context for a command or API call: the buffer, window, cursor and range,
---as they are now. Call it before anything changes windows (showing the agent, opening a
---picker). From the agent's terminal (or another non-code buffer) it captures the code
---window instead, and ignores the range, which was about the terminal.
---@param opts? duet.CaptureOpts
---@return duet.Context
function M.capture(opts)
  opts = opts or {}
  local mode = vim.fn.mode()
  local current = opts.win or vim.api.nvim_get_current_win()
  local win = code_window(current)
  local buf = vim.api.nvim_win_get_buf(win)
  local range
  if win == current then
    range = command_range(opts, mode)
  end

  local terminal = require("duet.terminal")
  local session = terminal.current()
  local agent
  if opts.agent then
    agent = require("duet.agents").get(opts.agent)
  elseif session then
    agent = session.agent
  else
    agent = require("duet.agents").get()
  end
  local cwd = session and session.root or terminal.root(vim.fn.getcwd(vim.fn.win_id2win(win)))
  return {
    buf = buf,
    win = win,
    cursor = vim.api.nvim_win_get_cursor(win),
    cwd = cwd,
    agent = agent or nil,
    range = range,
  }
end

-- Helpers for providers -----------------------------------------------------

---The file `buf` holds, as an absolute path, or nil for a buffer that isn't a file
---(no name, a special buftype, or a `scheme://` name).
---@param buf integer
---@return string|nil
function M.buf_path(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") then
    return nil
  end
  return vim.fs.normalize(name)
end

---`path` relative to the context's root (absolute when outside it).
---@param ctx duet.Context
---@param path string
---@return string
function M.relpath(ctx, path)
  return (require("duet.util").relpath(path, ctx.cwd))
end

---A location for humans and agents alike: `path`, `path:L10` or `path:L10-L20`. Pure.
---@param path string
---@param range? integer[] `{ start_line, end_line }`
---@return string
function M.location(path, range)
  if not range then
    return path
  end
  if range[1] == range[2] then
    return ("%s:L%d"):format(path, range[1])
  end
  return ("%s:L%d-L%d"):format(path, range[1], range[2])
end

---A reference to a file the agent can resolve: the adapter's `format_ref` when it has
---one, else `location()`. `path` is absolute; the agent sees it relative to the root.
---@param ctx duet.Context
---@param path string
---@param range? integer[] `{ start_line, end_line }` (equal for one line)
---@return string
function M.ref(ctx, path, range)
  local rel = M.relpath(ctx, path)
  local agent = ctx.agent
  if agent and agent.format_ref then
    local ok, ref = pcall(agent.format_ref, agent, rel, range)
    if ok and type(ref) == "string" then
      return ref
    end
    require("duet.log").error("context: %s format_ref failed: %s", agent.name, ref)
  end
  return M.location(rel, range)
end

---Keep at most `MAX_ITEMS` items. Pure.
---@generic T
---@param items T[]
---@return T[] kept
---@return integer dropped how many were left out
function M.truncate(items)
  if #items <= M.MAX_ITEMS then
    return items, 0
  end
  return vim.list_slice(items, 1, M.MAX_ITEMS), #items - M.MAX_ITEMS
end

---Join list lines, adding "… and N more" when items were dropped. Pure.
---@param lines string[]
---@param dropped integer
---@return string
function M.list_text(lines, dropped)
  if dropped > 0 then
    lines = vim.list_extend(vim.deepcopy(lines), { ("… and %d more"):format(dropped) })
  end
  return table.concat(lines, "\n")
end

---Indent every line of a message after the first by two spaces, so a multi-line message
---stays one list item. Pure.
---@param msg string
---@return string
function M.indent_rest(msg)
  return (vim.trim(msg):gsub("\r?\n", "\n  "))
end

-- Rendering ------------------------------------------------------------------

---Run one provider. A provider that fails is logged and counts as having nothing.
---@param name string
---@param ctx duet.Context
---@return duet.ContextResult|nil result nil when the provider has nothing to add
---@return string|nil err why there is no result, when it is not just empty
function M.get(name, ctx)
  local fn, load_err = provider(name)
  if not fn then
    return nil, load_err or ("context: unknown provider '%s'"):format(name)
  end
  local ok, result = pcall(fn, ctx)
  if not ok then
    local err = ("context: %s failed: %s"):format(name, result)
    require("duet.log").error("%s", err)
    return nil, err
  end
  if result == nil then
    return nil
  end
  if type(result) ~= "table" or type(result.text) ~= "string" then
    local err = ("context: %s returned %s, expected { text, data } or nil"):format(name, vim.inspect(result))
    require("duet.log").error("%s", err)
    return nil, err
  end
  if vim.trim(result.text) == "" then
    return nil
  end
  return result
end

---Replace `{name}` placeholders in `template` with what the providers return. Only
---registered names are replaced: other braces (`{foo}`, code, JSON) are left as typed.
---Provider text is not expanded again. A provider with nothing renders as "", and a line
---that held a placeholder and is blank after rendering is dropped. Block results (code,
---lists) go on lines of their own, splitting the line around them.
---@param template string
---@param ctx duet.Context
---@return string text
---@return duet.RenderInfo info
function M.render(template, ctx)
  local info = { used = {}, empty = {} }
  ---@type table<string, duet.ContextResult|false>
  local cache = {}
  local function resolve(name)
    if cache[name] == nil then
      if not provider(name) then
        return nil
      end
      cache[name] = M.get(name, ctx) or false
      info.used[#info.used + 1] = name
      if not cache[name] then
        info.empty[#info.empty + 1] = name
      end
    end
    return cache[name]
  end

  local out = {}
  for _, line in ipairs(vim.split(template, "\n", { plain = true })) do
    local current, had = {}, false
    local function flush()
      local text = table.concat(current)
      current = {}
      if not had or vim.trim(text) ~= "" then
        out[#out + 1] = text
      end
    end
    local pos = 1
    while true do
      local s, e, name = line:find("{([%w_]+)}", pos)
      if not s then
        break
      end
      current[#current + 1] = line:sub(pos, s - 1)
      local result = resolve(name)
      if result == nil then
        current[#current + 1] = line:sub(s, e)
      else
        had = true
        if result and result.block then
          local before = (table.concat(current):gsub("%s+$", ""))
          if before ~= "" then
            out[#out + 1] = before
          end
          current = {}
          out[#out + 1] = result.text
          -- Text after the block starts a new line.
          line, e = (line:sub(e + 1):gsub("^%s+", "")), 0
        elseif result then
          current[#current + 1] = result.text
        end
      end
      pos = e + 1
    end
    current[#current + 1] = line:sub(pos)
    flush()
  end
  return table.concat(out, "\n"), info
end

---Render text that is about to be sent. Fails when the text uses placeholders and all of
---them rendered empty: the text would lack what it was about (e.g. "Refactor {selection}"
---with no selection).
---@param text string
---@param ctx duet.Context
---@return string|nil text
---@return string|nil err e.g. "nothing to send: {selection} is empty"
function M.expand(text, ctx)
  local out, info = M.render(text, ctx)
  if #info.used > 0 and #info.empty == #info.used then
    local names = vim.tbl_map(function(name)
      return "{" .. name .. "}"
    end, info.empty)
    local verb = #names == 1 and "is" or "are"
    local hint = vim.tbl_contains(info.empty, "selection") and not ctx.range and " (no range or selection given)" or ""
    return nil, ("nothing to send: %s %s empty%s"):format(table.concat(names, ", "), verb, hint)
  end
  return out
end

return M
