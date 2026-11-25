---@brief Prompt templates (the `prompts` option) and `:Duet ask`.
--- A template is text with `{name}` placeholders (see |duet-context|), rendered with the
--- context captured when the command runs. See |:Duet-ask|.

local M = {}

---@class duet.AskOpts
---@field submit? boolean press Enter after the paste (default: true)
---@field agent? string agent to send to (see duet.SendOpts)
---@field ctx? duet.Context context to render with (default: captured now)

---Names of the configured prompts, sorted. Prompts set to `false` are left out.
---@return string[]
function M.names()
  local names = {}
  for name, template in pairs(require("duet.config").get().prompts) do
    if template then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---The template of prompt `name`, or nil if there is none.
---@param name string
---@return string|nil
function M.get(name)
  return require("duet.config").get().prompts[name] or nil
end

---Render prompt `name` and send it to the agent.
---@param name string
---@param opts? duet.AskOpts
---@return boolean|nil ok
---@return string|nil err
function M.ask(name, opts)
  vim.validate("name", name, "string")
  opts = opts or {}
  local template = M.get(name)
  if not template then
    local names = M.names()
    local available = #names > 0 and table.concat(names, ", ") or "none"
    return nil, ("ask: unknown prompt '%s' (available: %s)"):format(name, available)
  end
  local context = require("duet.context")
  local text, err, warning = context.expand(template, opts.ctx or context.capture({ agent = opts.agent }))
  if not text then
    return nil, ("ask: %s: %s"):format(name, err)
  end
  if warning then
    require("duet.util").notify(("ask: %s: %s"):format(name, warning), vim.log.levels.WARN)
  end
  return require("duet.send").send(text, { submit = opts.submit, agent = opts.agent })
end

---Complete prompt names for `:Duet ask`.
---@param arglead string
---@param args string[] words before the one being completed
---@return string[]
function M.complete(arglead, args)
  if #args > 0 then
    return {}
  end
  return vim.tbl_filter(function(name)
    return vim.startswith(name, arglead)
  end, M.names())
end

-- Command handler -------------------------------------------------------------

---`:[range]Duet[!] ask [name]`: send prompt `name`, or pick one with vim.ui.select. With
---`!`, only paste it. The context is captured first, before the picker opens.
---@param args string[]
---@param opts? duet.CommandOpts
---@return boolean|nil
---@return string|nil err
function M.cmd_ask(args, opts)
  opts = opts or {}
  if #args > 1 then
    return nil, "ask: usage: :Duet ask [name]"
  end
  local context = require("duet.context")
  local ctx = context.capture(opts)
  context.leave_visual()
  local submit = not opts.bang
  if args[1] then
    return M.ask(args[1], { ctx = ctx, submit = submit })
  end
  local names = M.names()
  if #names == 0 then
    return nil, "ask: no prompts configured (see the `prompts` option)"
  end
  vim.ui.select(names, {
    prompt = "duet ask",
    format_item = function(name)
      return ("%s: %s"):format(name, ((M.get(name) or ""):gsub("\n", " ⏎ ")))
    end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, err = M.ask(choice, { ctx = ctx, submit = submit })
    if not ok then
      require("duet.util").notify(err --[[@as string]], vim.log.levels.ERROR)
    end
  end)
  return true
end

return M
