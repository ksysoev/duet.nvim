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

return M
