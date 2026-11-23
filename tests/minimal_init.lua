-- Minimal init for tests and manual checks: `nvim --clean -u tests/minimal_init.lua`.
-- Adds the plugin and mini.nvim (cloned into .tests/ on first use) to 'runtimepath'.
-- It does not run tests; `mise run test` calls MiniTest.run() itself.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local mini_path = root .. "/.tests/mini.nvim"

if not vim.uv.fs_stat(mini_path) then
  local result = vim
    .system({
      "git",
      "clone",
      "--filter=blob:none",
      "--depth",
      "1",
      "--branch",
      "stable",
      "https://github.com/nvim-mini/mini.nvim",
      mini_path,
    })
    :wait()
  if result.code ~= 0 then
    vim.api.nvim_echo(
      { { "minimal_init: failed to clone mini.nvim: " .. (result.stderr or "") } },
      true,
      { err = true }
    )
    vim.cmd("cquit 1")
  end
end

vim.opt.runtimepath:prepend(mini_path)
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- --noplugin (used by the test task) skips plugin/ scripts; load ours explicitly.
vim.cmd("runtime! plugin/duet.lua")

require("mini.test").setup()
