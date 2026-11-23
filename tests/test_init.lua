local MiniTest = require("mini.test")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["require('duet')"] = MiniTest.new_set()

T["require('duet')"]["returns a module with setup()"] = function()
  local duet = require("duet")
  eq(type(duet), "table")
  eq(type(duet.setup), "function")
end

T["require('duet')"]["setup() accepts"] = MiniTest.new_set({
  parametrize = { { "no options", nil }, { "an empty table", {} } },
})

T["require('duet')"]["setup() accepts"]["%s"] = function(_, opts)
  MiniTest.expect.no_error(function()
    require("duet").setup(opts)
  end)
end

return T
