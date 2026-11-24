---@brief Dispatcher for the :Duet command and its subcommand registry.
--- plugin/duet.lua calls `run` and `complete`. Built-in subcommands are registered at the
--- bottom of this file with closures that `require` their feature module only when they
--- run, so that lazy loading keeps working. See |:Duet|.

local M = {}

---@class duet.CommandOpts : vim.api.keyset.create_user_command.command_args
---@field rest string raw text after the subcommand word, with its original spacing

---@class duet.Subcommand
---@field impl fun(args: string[], opts: duet.CommandOpts): any, string? runs the subcommand; may return nil, err
---@field complete? fun(arglead: string, args: string[]): string[] completes the argument being typed; `args` are the complete words before it
---@field desc? string one-line description

---@type table<string, duet.Subcommand>
local registry = {}

---Register a subcommand of :Duet. Registering an existing name replaces it.
---@param name string
---@param spec duet.Subcommand
function M.register(name, spec)
  vim.validate("name", name, "string")
  vim.validate("spec", spec, "table")
  vim.validate("spec.impl", spec.impl, "function")
  vim.validate("spec.complete", spec.complete, "function", true)
  vim.validate("spec.desc", spec.desc, "string", true)
  if name == "" or name:find("%s") then
    error(("commands: invalid subcommand name %q"):format(name), 2)
  end
  registry[name] = spec
end

---Remove a subcommand of :Duet. Removing an unknown name does nothing.
---@param name string
function M.unregister(name)
  registry[name] = nil
end

---Names of the registered subcommands, sorted.
---@return string[]
function M.names()
  local names = vim.tbl_keys(registry)
  table.sort(names)
  return names
end

local function usage()
  local names = M.names()
  local list = #names > 0 and table.concat(names, ", ") or "(none yet)"
  return "usage: :Duet <subcommand> [args]. Subcommands: " .. list
end

local function dispatch(name, spec, args, opts)
  local log = require("duet.log")
  local util = require("duet.util")
  local ok, result, err = xpcall(spec.impl, debug.traceback, args, opts)
  if not ok then
    log.error("subcommand %s failed: %s", name, result)
    local first = tostring(result):match("^[^\n]*")
    util.notify(("%s: %s"):format(name, first), vim.log.levels.ERROR)
    return
  end
  if result == nil and err ~= nil then
    util.notify(tostring(err), vim.log.levels.ERROR)
  end
end

---Run :Duet with the given command options.
---@param opts vim.api.keyset.create_user_command.command_args
function M.run(opts)
  local util = require("duet.util")
  local fargs = opts.fargs or {}
  local name = fargs[1]
  local cmd_opts = opts --[[@as duet.CommandOpts]]

  if name == nil then
    local toggle = registry.toggle
    if toggle then
      cmd_opts.rest = ""
      dispatch("toggle", toggle, {}, cmd_opts)
    else
      util.notify(usage(), vim.log.levels.INFO)
    end
    return
  end

  local spec = registry[name]
  if not spec then
    local names = M.names()
    local available = #names > 0 and table.concat(names, ", ") or "(none yet)"
    util.notify(("unknown subcommand '%s'. Available: %s"):format(name, available), vim.log.levels.ERROR)
    return
  end

  cmd_opts.rest = (opts.args or ""):match("^%s*%S+%s?(.*)$") or ""
  dispatch(name, spec, vim.list_slice(fargs, 2), cmd_opts)
end

---Strip everything up to and including the command name (range, `!`, abbreviations).
---@param line string
---@return string|nil rest text after the command name, or nil if it wasn't found
local function after_command(line)
  local pos = 1
  while true do
    -- %f[%a] rather than %f[%w], so a range ending in a digit ("5,10Duet") still matches.
    local s, e = line:find("%f[%a]D%a*!?%s+", pos)
    if not s then
      return nil
    end
    local word = line:sub(s, e):match("^(%a+)")
    if vim.startswith("Duet", word) then
      return line:sub(e + 1)
    end
    pos = e + 1
  end
end

---Complete :Duet arguments.
---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  local rest = after_command(cmdline:sub(1, cursorpos))
  if rest == nil then
    return {}
  end
  local words = vim.split(rest, "%s+", { trimempty = true })
  if rest == "" or rest:match("%s$") then
    words[#words + 1] = ""
  end

  if #words <= 1 then
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arglead)
    end, M.names())
  end

  local spec = registry[words[1]]
  if not spec or not spec.complete then
    return {}
  end
  local ok, result = pcall(spec.complete, arglead, vim.list_slice(words, 2, #words - 1))
  if not ok or type(result) ~= "table" then
    require("duet.log").error("completion for %s failed: %s", words[1], result)
    return {}
  end
  return result
end

-- Built-in subcommands. Each closure requires its feature module only when it runs, so
-- lazy loading keeps working.

local function complete_agent(arglead, args)
  if #args > 0 then
    return {}
  end
  return require("duet.agents").complete_names(arglead)
end

M.register("toggle", {
  desc = "Toggle the agent terminal",
  impl = function(args, opts)
    return require("duet.terminal").cmd_toggle(args, opts)
  end,
  complete = complete_agent,
})

M.register("open", {
  desc = "Open and focus the agent terminal",
  impl = function(args, opts)
    return require("duet.terminal").cmd_open(args, opts)
  end,
  complete = complete_agent,
})

M.register("close", {
  desc = "Hide the agent terminal (:Duet! close stops the agent)",
  impl = function(args, opts)
    return require("duet.terminal").cmd_close(args, opts)
  end,
  complete = complete_agent,
})

M.register("restart", {
  desc = "Restart the agent",
  impl = function(args, opts)
    return require("duet.terminal").cmd_restart(args, opts)
  end,
  complete = complete_agent,
})

return M
