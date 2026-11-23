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

return M
