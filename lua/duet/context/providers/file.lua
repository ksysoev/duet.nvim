---@brief Context providers `{file}` and `{this}`: references to the current file.

local M = {}

---`{file}`: a reference to the current file, e.g. `@src/main.lua` for Claude.
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.file(ctx)
  local context = require("duet.context")
  local path = context.buf_path(ctx.buf)
  if not path then
    return nil
  end
  return {
    text = context.ref(ctx, path),
    data = { path = context.relpath(ctx, path), filetype = vim.bo[ctx.buf].filetype },
  }
end

---`{this}`: a reference to the range given, or to the cursor line.
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.this(ctx)
  local context = require("duet.context")
  local path = context.buf_path(ctx.buf)
  if not path then
    return nil
  end
  local range = ctx.range and { ctx.range.start_line, ctx.range.end_line } or { ctx.cursor[1], ctx.cursor[1] }
  return {
    text = context.ref(ctx, path, range),
    data = { path = context.relpath(ctx, path), start_line = range[1], end_line = range[2] },
  }
end

return M
