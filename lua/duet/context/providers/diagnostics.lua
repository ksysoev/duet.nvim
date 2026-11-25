---@brief Context providers `{diagnostics}` and `{diagnostics_all}`.
--- Each diagnostic is one `path:line: [SEVERITY] message` line, errors first.

local M = {}

---@class duet.ContextDiagnostic
---@field path string relative path, or "[No Name]"
---@field line integer 1-based
---@field col integer 1-based
---@field end_line integer 1-based
---@field severity string "ERROR", "WARN", "INFO" or "HINT"
---@field message string
---@field source? string
---@field code? string

---@param a vim.Diagnostic
---@param b vim.Diagnostic
---@param paths table<integer, string>
local function before(a, b, paths)
  if a.severity ~= b.severity then
    return a.severity < b.severity
  end
  if paths[a.bufnr] ~= paths[b.bufnr] then
    return paths[a.bufnr] < paths[b.bufnr]
  end
  if a.lnum ~= b.lnum then
    return a.lnum < b.lnum
  end
  return a.col < b.col
end

---Render diagnostics as a list, sorted by severity, then path and position.
---@param ctx duet.Context
---@param diagnostics vim.Diagnostic[]
---@return duet.ContextResult|nil
local function render(ctx, diagnostics)
  if #diagnostics == 0 then
    return nil
  end
  local context = require("duet.context")
  local paths = {}
  for _, d in ipairs(diagnostics) do
    if not paths[d.bufnr] then
      local path = context.buf_path(d.bufnr)
      paths[d.bufnr] = path and context.relpath(ctx, path) or "[No Name]"
    end
  end
  diagnostics = vim.deepcopy(diagnostics)
  table.sort(diagnostics, function(a, b)
    return before(a, b, paths)
  end)
  local kept, dropped = context.truncate(diagnostics)

  local lines, items = {}, {}
  for _, d in ipairs(kept) do
    local item = {
      path = paths[d.bufnr],
      line = d.lnum + 1,
      col = d.col + 1,
      end_line = (d.end_lnum or d.lnum) + 1,
      severity = vim.diagnostic.severity[d.severity],
      message = d.message,
      source = d.source,
      code = d.code ~= nil and tostring(d.code) or nil,
    }
    items[#items + 1] = item
    lines[#lines + 1] = ("%s:%d: [%s] %s"):format(item.path, item.line, item.severity, context.indent_rest(d.message))
  end
  return {
    text = context.list_text(lines, dropped),
    block = true,
    data = { items = items, truncated = dropped > 0 and dropped or nil },
  }
end

---`{diagnostics}`: the current buffer's diagnostics, or those overlapping the range.
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.diagnostics(ctx)
  local list = vim.diagnostic.get(ctx.buf)
  local range = ctx.range
  if range then
    list = vim.tbl_filter(function(d)
      local first, last = d.lnum + 1, (d.end_lnum or d.lnum) + 1
      return first <= range.end_line and last >= range.start_line
    end, list)
  end
  return render(ctx, list)
end

---`{diagnostics_all}`: the diagnostics of every buffer.
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.diagnostics_all(ctx)
  return render(ctx, vim.diagnostic.get(nil))
end

return M
