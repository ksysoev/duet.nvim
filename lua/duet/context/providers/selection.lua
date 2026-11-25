---@brief Context provider `{selection}`: the selected code as a fenced code block.

local M = {}

local REGION_TYPES = { char = "v", block = "\22" }

---A code fence longer than any run of backticks in `text`, so the text can't close it.
---Pure.
---@param text string
---@return string
function M.fence(text)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return string.rep("`", math.max(3, longest + 1))
end

---The lines of the range: whole lines, or the exact region for a character-wise or
---block-wise selection.
---@param buf integer
---@param range duet.Range
---@return string[]
local function range_lines(buf, range)
  local type = REGION_TYPES[range.mode]
  if not type then
    return vim.api.nvim_buf_get_lines(buf, range.start_line - 1, range.end_line, false)
  end
  return vim.fn.getregion(
    { buf, range.start_line, range.start_col, 0 },
    { buf, range.end_line, range.end_col, 0 },
    { type = type }
  )
end

---`{selection}`: the range given, as a fenced code block with the file's language,
---below a `path:L10-L20` line (left out for a buffer that isn't a file).
---@param ctx duet.Context
---@return duet.ContextResult|nil
function M.selection(ctx)
  local range = ctx.range
  if not range then
    return nil
  end
  local context = require("duet.context")
  local text = table.concat(range_lines(ctx.buf, range), "\n")
  if vim.trim(text) == "" then
    return nil
  end
  local path = context.buf_path(ctx.buf)
  local rel = path and context.relpath(ctx, path)
  local filetype = vim.bo[ctx.buf].filetype
  local fence = M.fence(text)
  local lines = {}
  if rel then
    lines[#lines + 1] = context.location(rel, { range.start_line, range.end_line })
  end
  vim.list_extend(lines, { fence .. filetype, text, fence })
  return {
    text = table.concat(lines, "\n"),
    block = true,
    data = {
      path = rel,
      filetype = filetype,
      start_line = range.start_line,
      end_line = range.end_line,
      start_col = range.start_col,
      end_col = range.end_col,
      mode = range.mode,
      text = text,
    },
  }
end

return M
