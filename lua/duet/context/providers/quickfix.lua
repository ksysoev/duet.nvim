---@brief Context provider `{quickfix}`: the current quickfix list.

local M = {}

---`{quickfix}`: the entries of the quickfix list, one `path:line:col: text` line each,
---in list order. Lines that point nowhere (text an error format didn't match) are left
---out; Vim marks entries without a line number invalid too, but those point at a file.
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.quickfix(ctx)
  local context = require("duet.context")
  local qf = vim.fn.getqflist({ items = 1, title = 1 })
  local entries = vim.tbl_filter(function(item)
    return item.valid == 1 or item.bufnr > 0
  end, qf.items or {})
  if #entries == 0 then
    return nil
  end
  local kept, dropped = context.truncate(entries)

  local lines, items = {}, {}
  for _, entry in ipairs(kept) do
    local path = entry.bufnr > 0 and context.buf_path(entry.bufnr)
    local name = path and context.relpath(ctx, path)
      or (entry.bufnr > 0 and vim.api.nvim_buf_get_name(entry.bufnr))
      or ""
    if name == "" then
      name = "[No Name]"
    end
    local item = {
      path = name,
      line = entry.lnum > 0 and entry.lnum or nil,
      col = entry.col > 0 and entry.col or nil,
      type = entry.type ~= "" and entry.type or nil,
      text = vim.trim(entry.text),
    }
    items[#items + 1] = item
    local where = name
    if item.line then
      where = where .. ":" .. item.line
      if item.col then
        where = where .. ":" .. item.col
      end
    end
    lines[#lines + 1] = ("%s: %s"):format(where, context.indent_rest(entry.text))
  end
  return {
    text = context.list_text(lines, dropped),
    block = true,
    data = { title = qf.title, items = items, truncated = dropped > 0 and dropped or nil },
  }
end

return M
