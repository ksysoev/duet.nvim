local MiniTest = require("mini.test")
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
    end,
    post_once = child.stop,
  },
})

local cases = {
  {
    name = "defines :Duet",
    check = function()
      eq(child.fn.exists(":Duet"), 2)
    end,
  },
  {
    name = "loads no duet modules at startup",
    check = function()
      local loaded = child.lua_get([[vim.tbl_filter(function(name)
        return name == "duet" or vim.startswith(name, "duet.")
      end, vim.tbl_keys(package.loaded))]])
      eq(loaded, {})
    end,
  },
  {
    name = "starts without errors",
    check = function()
      eq(child.v.errmsg, "")
    end,
  },
  {
    name = ":Duet with no args runs without errors",
    check = function()
      -- :Duet starts the default agent; use a harmless command instead of the real CLI.
      child.lua([[require("duet").setup({ agents = { claude = { cmd = { "sh", "-c", "cat" } } } })]])
      MiniTest.expect.no_error(function()
        child.cmd("Duet")
      end)
      eq(child.v.errmsg, "")
    end,
  },
  {
    name = "defines :Duet only once when sourced again",
    check = function()
      MiniTest.expect.no_error(function()
        child.cmd("runtime! plugin/duet.lua")
      end)
      eq(child.fn.exists(":Duet"), 2)
    end,
  },
}

T["plugin/duet.lua"] = MiniTest.new_set()
for _, case in ipairs(cases) do
  T["plugin/duet.lua"][case.name] = case.check
end

return T
