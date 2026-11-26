---@brief Context provider `{buffers}`: the listed file buffers.

local M = {}

---`{buffers}`: a reference to each listed buffer that holds a file, one per line, in
---buffer number order.
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.buffers(ctx)
  local context = require("duet.context")
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.bo[buf].buflisted and context.buf_path(buf)
    if path then
      found[#found + 1] = { buf = buf, path = path }
    end
  end
  if #found == 0 then
    return nil
  end
  local kept, dropped = context.truncate(found)

  local lines, items = {}, {}
  for _, entry in ipairs(kept) do
    lines[#lines + 1] = context.ref(ctx, entry.path)
    items[#items + 1] = { path = context.relpath(ctx, entry.path), modified = vim.bo[entry.buf].modified }
  end
  return {
    text = context.list_text(lines, dropped),
    block = true,
    data = { items = items, truncated = dropped > 0 and dropped or nil },
  }
end

return M
