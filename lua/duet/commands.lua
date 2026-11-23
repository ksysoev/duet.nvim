---@brief Dispatcher for the :Duet command.
--- Placeholder until the subcommand registry lands (#3). plugin/duet.lua already
--- calls `run` and `complete`, so #3 only replaces this module.

local M = {}

---Run :Duet with the given command options.
---@param opts vim.api.keyset.create_user_command.command_args
function M.run(opts)
  local _ = opts
  vim.notify("[duet] no subcommands yet", vim.log.levels.INFO)
end

---Complete :Duet arguments.
---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  local _ = { arglead, cmdline, cursorpos }
  return {}
end

return M
