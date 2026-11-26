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

---The lines of a block made with `$`: each line from the block's left screen column to its
---end, or "" for a line that ends before it. A tab only partly inside the block is taken
---whole (a yank pads it with spaces instead). Screen columns depend on the window's
---options, such as 'tabstop', so they are measured in `win`.
---@param win integer window showing the buffer
---@param range duet.Range
---@return string[]
local function block_to_end(win, range)
  return vim.api.nvim_win_call(win, function()
    local left = math.min(
      vim.fn.virtcol({ range.start_line, range.start_col }, 1)[1],
      vim.fn.virtcol({ range.end_line, range.end_col }, 1)[1]
    )
    local lines = {}
    for lnum = range.start_line, range.end_line do
      local line = vim.fn.getline(lnum)
      if vim.fn.strdisplaywidth(line) < left then
        lines[#lines + 1] = ""
      else
        lines[#lines + 1] = line:sub(vim.fn.virtcol2col(win, lnum, left))
      end
    end
    return lines
  end)
end

---The lines of the range: whole lines, or the exact region for a character-wise or
---block-wise selection.
---@param ctx duet.Context
---@param range duet.Range
---@return string[]
local function range_lines(ctx, range)
  local buf = ctx.buf
  local type = REGION_TYPES[range.mode]
  if not type then
    return vim.api.nvim_buf_get_lines(buf, range.start_line - 1, range.end_line, false)
  end
  if range.to_end then
    return block_to_end(ctx.win, range)
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
  local text = table.concat(range_lines(ctx, range), "\n")
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
      to_end = range.to_end,
      text = text,
    },
  }
end

return M
