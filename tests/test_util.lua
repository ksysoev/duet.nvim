local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = { pre_case = h.reset_modules } })

T["git_root()"] = MiniTest.new_set()

T["git_root()"]["finds the repository root"] = function()
  local root = h.tmp_git_repo({ ["a/b/file.lua"] = "x" })
  local util = require("duet.util")
  local cases = {
    { name = "from the root", path = root },
    { name = "from a nested directory", path = root .. "/a/b" },
    { name = "from a file path", path = root .. "/a/b/file.lua" },
  }
  for _, case in ipairs(cases) do
    eq({ case.name, util.git_root(case.path) }, { case.name, root })
  end
end

T["git_root()"]["returns nil outside a repository"] = function()
  local dir = h.tmp_dir()
  eq(require("duet.util").git_root(dir), nil)
end

T["git_root()"]["handles a worktree whose .git is a file"] = function()
  local root = h.tmp_git_repo({ ["f.txt"] = "x" })
  h.run({ "git", "add", "." }, root)
  h.run({ "git", "commit", "-q", "-m", "init" }, root)
  local worktree = h.tmp_dir() .. "/wt"
  h.run({ "git", "worktree", "add", "-q", worktree }, root)
  eq(vim.uv.fs_stat(worktree .. "/.git").type, "file")
  eq(require("duet.util").git_root(worktree .. "/f.txt"), worktree)
end

T["relpath()"] = MiniTest.new_set({
  parametrize = {
    { "inside", "/a/b/c.lua", "/a/b", "c.lua", true },
    { "nested", "/a/b/c/d.lua", "/a/b", "c/d.lua", true },
    { "root with a trailing slash", "/a/b/c.lua", "/a/b/", "c.lua", true },
    { "path with .. segments", "/a/b/x/../c.lua", "/a/b", "c.lua", true },
    { "path equal to root", "/a/b", "/a/b", ".", true },
    { "outside", "/x/y.lua", "/a/b", "/x/y.lua", false },
    { "sibling with a shared prefix", "/a/bc/d.lua", "/a/b", "/a/bc/d.lua", false },
  },
})

T["relpath()"]["%s"] = function(_, path, root, expected, inside)
  local rel, is_inside = require("duet.util").relpath(path, root)
  eq(rel, expected)
  eq(is_inside, inside)
end

T["notify()"] = MiniTest.new_set()

T["notify()"]["prefixes the message and defaults to INFO"] = function()
  local capture = h.capture_notify()
  require("duet.util").notify("hello")
  require("duet.util").notify("bad", vim.log.levels.ERROR)
  capture.restore()
  eq(capture.messages, {
    { msg = "[duet] hello", level = vim.log.levels.INFO },
    { msg = "[duet] bad", level = vim.log.levels.ERROR },
  })
end

T["notify()"]["works from a fast event"] = function()
  local capture = h.capture_notify()
  local util = require("duet.util")
  local timer = assert(vim.uv.new_timer())
  timer:start(0, 0, function()
    util.notify("from timer")
  end)
  vim.wait(1000, function()
    return #capture.messages > 0
  end)
  timer:close()
  capture.restore()
  eq(capture.messages, { { msg = "[duet] from timer", level = vim.log.levels.INFO } })
end

return T
