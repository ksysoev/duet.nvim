---@brief Small shared helpers: user notifications, paths and code windows.

local M = {}

local PREFIX = "[duet] "

---Show a message to the user, prefixed with "[duet]".
---Safe to call from fast events (luv callbacks): the call is scheduled then.
---@param msg string
---@param level? integer one of vim.log.levels (default INFO)
function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  local function show()
    vim.notify(PREFIX .. msg, level, { title = "duet" })
  end
  if vim.in_fast_event() then
    vim.schedule(show)
  else
    show()
  end
end

---Find the git root that contains `path`.
---Uses only the filesystem (no git subprocess), so it handles worktrees and
---submodules, where `.git` is a file. With a string path it is safe in fast events;
---without one it reads the current buffer's name, which is not.
---@param path? string file or directory (default: current buffer's file, else the cwd)
---@return string|nil root absolute path of the repository root, or nil outside a repo
function M.git_root(path)
  if path == nil or path == "" then
    path = vim.api.nvim_buf_get_name(0)
    if path == "" then
      path = vim.uv.cwd() or "."
    end
  end
  path = vim.fs.normalize(vim.fs.abspath(path))
  return vim.fs.root(path, ".git")
end

---Make `path` relative to `root`.
---@param path string
---@param root string
---@return string path relative to root ("." for root itself), or the absolute normalized path if outside
---@return boolean inside whether `path` is inside `root`
function M.relpath(path, root)
  local abs = vim.fs.normalize(vim.fs.abspath(path))
  local base = vim.fs.normalize(vim.fs.abspath(root))
  local rel = vim.fs.relpath(base, abs)
  if rel == nil then
    return abs, false
  end
  return rel, true
end

---Whether `buf` holds code the user works on, rather than a terminal, help, a list etc.
---@param buf integer
---@return boolean
function M.is_code(buf)
  return vim.bo[buf].buftype == "" and vim.b[buf].duet_session == nil
end

---The window that shows code: the current one when it does, else the previous window,
---else the first non-floating window showing code in the tab, else the current one.
---@param accept? fun(win: integer): boolean skips a window that shows code but fails
---this, e.g. one a file cannot be opened in
---@return integer win
---@return boolean found whether `win` shows code (and passes `accept`)
function M.code_window(accept)
  local function usable(id)
    return M.is_code(vim.api.nvim_win_get_buf(id)) and (accept == nil or accept(id))
  end
  local win = vim.api.nvim_get_current_win()
  if usable(win) then
    return win, true
  end
  local candidates = { vim.fn.win_getid(vim.fn.winnr("#")) }
  vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(0))
  for _, id in ipairs(candidates) do
    if id ~= 0 and vim.api.nvim_win_is_valid(id) and vim.api.nvim_win_get_config(id).relative == "" and usable(id) then
      return id, true
    end
  end
  return win, false
end

return M
