local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local child = h.new_child()

local function checkhealth()
  child.cmd("checkhealth duet")
  return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function has(text, needle)
  return text:find(needle, 1, true) ~= nil
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = child.setup,
    post_once = child.stop,
  },
})

T["shows the Neovim version and git"] = function()
  local report = checkhealth()
  eq(has(report, "OK Neovim " .. child.lua_get("tostring(vim.version())")), true)
  eq(has(report, "OK git found on PATH"), true)
  eq(has(report, "OK setup() not called, using the default config"), true)
  eq(has(report, "log file: "), true)
end

T["reports config problems"] = MiniTest.new_set({
  parametrize = {
    { "unknown keys", "{ foo = 1 }", "WARNING unknown option(s): foo" },
    { "invalid values", "{ terminal = 'x' }", "ERROR invalid config: terminal: expected table, got string" },
    { "a valid config", "{ agent = 'claude' }", "OK config is valid" },
  },
})

T["reports config problems"]["%s"] = function(_, opts, expected)
  child.lua("vim.notify = function() end; require('duet').setup(" .. opts .. ")")
  eq(has(checkhealth(), expected), true)
end

T["a failing check does not hide the others"] = function()
  child.lua([[
    local health = require("duet.health")
    health.register("broken", function() error("oops") end)
    health.register("after", function() vim.health.ok("still runs") end)
  ]])
  local report = checkhealth()
  eq(has(report, "check failed:"), true)
  eq(has(report, "oops"), true)
  eq(has(report, "OK still runs"), true)
  eq(has(report, "OK git found on PATH"), true)
end

T["register() replaces a check with the same name"] = function()
  child.lua([[
    local health = require("duet.health")
    health.register("extra", function() vim.health.ok("first") end)
    health.register("extra", function() vim.health.ok("second") end)
  ]])
  local report = checkhealth()
  eq(has(report, "OK first"), false)
  eq(has(report, "OK second"), true)
end

return T
