---@brief Small shared helpers: user notifications and path handling.

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

return M
