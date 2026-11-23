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

T["agents"] = MiniTest.new_set()

---Write an executable script that prints `output` and exits with `code`.
local function fake_bin(output, code)
  local path = h.tmp_dir() .. "/fake-claude"
  vim.fn.writefile({ "#!/bin/sh", ("echo '%s'"):format(output), ("exit %d"):format(code or 0) }, path)
  vim.uv.fs_chmod(path, tonumber("755", 8))
  return path
end

local function setup_child(opts)
  child.lua("vim.notify = function() end; require('duet').setup(...)", { opts })
end

T["agents"]["reports a missing binary as an error"] = function()
  setup_child({ agents = { claude = { cmd = { "duet-no-such-binary" } } } })
  local report = checkhealth()
  eq(has(report, "ERROR claude (default): `duet-no-such-binary` not found on PATH"), true)
  eq(has(report, "set `agents.claude.cmd` to the full path"), true)
end

T["agents"]["reports the binary and its version"] = function()
  local bin = fake_bin("9.9.9 (Claude Code)")
  setup_child({ agents = { claude = { cmd = { bin } } } })
  local report = checkhealth()
  eq(has(report, ("OK claude (default): `%s` found on PATH"):format(bin)), true)
  eq(has(report, "OK claude version: 9.9.9 (Claude Code)"), true)
end

T["agents"]["warns when --version fails"] = function()
  setup_child({ agents = { claude = { cmd = { fake_bin("boom", 3) } } } })
  eq(has(checkhealth(), "WARNING claude --version exited with 3"), true)
end

T["agents"]["reports an unknown default agent as an error"] = function()
  setup_child({ agent = "nope" })
  eq(has(checkhealth(), "ERROR agents: unknown agent 'nope' (available: claude)"), true)
end

T["agents"]["warns about overrides for an unknown agent"] = function()
  setup_child({ agents = { claude = { cmd = { fake_bin("1.0") } }, nope = { args = {} } } })
  eq(has(checkhealth(), "WARNING agents: unknown agent 'nope' (available: claude)"), true)
end

T["agents"]["lists features a registered agent lacks"] = function()
  child.lua([[
    require("duet.agents").register({
      name = "basic",
      cmd = { "sh" },
      capabilities = { mcp = false, plan_hook = false, system_prompt = true },
      launch = function() end,
    })
  ]])
  setup_child({ agent = "basic" })
  local report = checkhealth()
  eq(has(report, "OK basic (default): `sh` found on PATH"), true)
  eq(has(report, "basic: not supported, so disabled: agent → editor tools (MCP), plan review"), true)
end

return T
