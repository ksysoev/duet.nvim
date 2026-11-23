-- Shared test helpers. Require with `local h = dofile("tests/helpers.lua")`.

local MiniTest = require("mini.test")

local H = {}

---Replace vim.notify with a recorder.
---@return { messages: { msg: string, level: integer }[], restore: fun() }
function H.capture_notify()
  local original = vim.notify
  local capture = { messages = {} }
  vim.notify = function(msg, level)
    table.insert(capture.messages, { msg = msg, level = level })
  end
  function capture.restore()
    vim.notify = original
  end
  return capture
end

---Unload all duet modules so the next require starts from a clean state.
function H.reset_modules()
  for name in pairs(package.loaded) do
    if name == "duet" or vim.startswith(name, "duet.") then
      package.loaded[name] = nil
    end
  end
end

---Create a fresh temporary directory.
---@return string path absolute, symlinks resolved
function H.tmp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir) or dir
end

---Run a command synchronously (tests only) and fail the test on a non-zero exit.
---@param cmd string[]
---@param cwd? string
---@return string stdout
function H.run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(("command failed (%d): %s\n%s"):format(result.code, table.concat(cmd, " "), result.stderr or ""))
  end
  return result.stdout or ""
end

---Create a temporary git repository with optional files.
---@param files? table<string, string> relative path -> content
---@return string root
function H.tmp_git_repo(files)
  local root = H.tmp_dir()
  H.run({ "git", "init", "-q" }, root)
  H.run({ "git", "config", "user.name", "duet-test" }, root)
  H.run({ "git", "config", "user.email", "duet-test@example.invalid" }, root)
  for path, content in pairs(files or {}) do
    local full = vim.fs.joinpath(root, path)
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    local f = assert(io.open(full, "w"))
    f:write(content)
    f:close()
  end
  return root
end

---Create a child Neovim and start it with the test init.
---@param env? table<string, string> environment variables for the child process
---@return table child MiniTest child Neovim
function H.new_child(env)
  local child = MiniTest.new_child_neovim()
  local start = child.restart
  ---Restart the child with the test init and `env`.
  function child.setup()
    -- The child inherits this process's environment, so set it around the start.
    local saved = {}
    for key, value in pairs(env or {}) do
      saved[key] = vim.env[key] or false
      vim.env[key] = value
    end
    start({ "-u", "tests/minimal_init.lua" })
    for key, value in pairs(saved) do
      vim.env[key] = value or nil
    end
  end
  return child
end

return H
