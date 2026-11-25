---@mod duet duet.nvim
---@brief Pair with AI coding agents inside Neovim.
--- This module stays thin: public functions require their feature module when called.

local M = {}

---Configure duet. Calling it is optional; without it the defaults apply.
---See |duet-config|.
---@param opts? duet.Config|table user options, merged over the defaults
---@return boolean|nil ok
---@return string|nil err validation error, also shown to the user
function M.setup(opts)
  return require("duet.config").setup(opts)
end

---Toggle the agent terminal for the current project. See |duet.toggle()|.
---@param agent? string agent name
---@return duet.Session|nil
---@return string|nil err
function M.toggle(agent)
  return require("duet.terminal").toggle(agent)
end

---Open and focus the agent terminal, starting the agent if needed. See |duet.open()|.
---@param agent? string agent name
---@return duet.Session|nil
---@return string|nil err
function M.open(agent)
  return require("duet.terminal").open(agent)
end

---Hide the agent terminal, or stop the agent with `opts.stop`. See |duet.close()|.
---@param opts? { stop?: boolean, agent?: string }
---@return boolean|nil ok
---@return string|nil err
function M.close(opts)
  return require("duet.terminal").close(opts)
end

---Send text to the agent as one paste, and submit it unless `opts.submit` is false.
---Starts the agent if needed. Returns once the text is queued. See |duet.send()|.
---@param text string
---@param opts? duet.SendOpts
---@return boolean|nil ok
---@return string|nil err
function M.send(text, opts)
  return require("duet.send").send(text, opts)
end

---Leave visual mode, after its selection has been captured, as a `:` mapping would.
local function leave_visual()
  if vim.fn.mode():match("^[vV\22]") then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
end

---Send prompt template `name` (see |duet-config-prompts|) with the current context: the
---visual selection when called from visual mode. See |duet.ask()|.
---@param name string
---@param opts? duet.AskOpts
---@return boolean|nil ok
---@return string|nil err
function M.ask(name, opts)
  opts = vim.deepcopy(opts or {})
  opts.ctx = opts.ctx or require("duet.context").capture({ agent = opts.agent })
  leave_visual()
  return require("duet.context.prompts").ask(name, opts)
end

---Expand the `{name}` placeholders in `template` with the current context: the visual
---selection when called from visual mode. Nothing is sent. See |duet.render()|.
---@param template string
---@return string text
---@return duet.RenderInfo info which placeholders were used, and which were empty
function M.render(template)
  vim.validate("template", template, "string")
  local context = require("duet.context")
  return context.render(template, context.capture())
end

return M
