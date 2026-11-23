local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

-- Each case runs in a child whose stdpath("log") points at a fresh temporary directory.
local child

local function start(env)
  env = vim.tbl_extend("force", { XDG_STATE_HOME = h.tmp_dir() }, env or {})
  child = h.new_child(env)
  child.setup()
end

local function log_lines()
  return child.lua([[
    local path = require("duet.log").path()
    if not vim.uv.fs_stat(path) then return {} end
    return vim.fn.readfile(path)
  ]])
end

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      if child then
        child.stop()
      end
    end,
  },
})

T["writes under stdpath('log')"] = function()
  start()
  local path = child.lua_get([[require("duet.log").path()]])
  eq(vim.endswith(path, "/duet.log"), true)
  eq(vim.startswith(path, child.lua_get("vim.env.XDG_STATE_HOME")), true)
end

T["filters by level"] = MiniTest.new_set({
  parametrize = {
    { "default level warn drops info", false, "info", 0 },
    { "default level warn keeps warn", false, "warn", 1 },
    { "default level warn keeps error", false, "error", 1 },
    { "debug keeps debug", "debug", "debug", 1 },
    { "debug drops trace", "debug", "trace", 0 },
    { "off drops error", "off", "error", 0 },
    { "numeric level", vim.log.levels.INFO, "info", 1 },
  },
})

T["filters by level"]["%s"] = function(_, level, method, count)
  start()
  if level ~= false then
    child.lua("require('duet').setup({ log_level = ... })", { level })
  end
  child.lua("require('duet.log')[...]('message %d', 1)", { method })
  eq(#log_lines(), count)
end

T["formats the line with level and tag"] = function()
  start()
  child.lua([[
    local log = require("duet.log")
    log.error("plain %s", "text")
    log.set_tag("bridge:1")
    log.error("tagged")
  ]])
  local lines = log_lines()
  eq(#lines, 2)
  eq(lines[1]:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d ERROR %[parent%] plain text$") ~= nil, true)
  eq(lines[2]:match(" ERROR %[bridge:1%] tagged$") ~= nil, true)
end

T["inspects tables and survives a bad format string"] = function()
  start()
  child.lua([[
    local log = require("duet.log")
    log.error("value %s", { a = 1 })
    log.error("bad %d", "not a number")
  ]])
  local lines = log_lines()
  eq(lines[1]:match("value { a = 1 }$") ~= nil, true)
  eq(lines[2]:match("bad %%d$") ~= nil, true)
end

T["$DUET_LOG_LEVEL overrides the config"] = function()
  start({ DUET_LOG_LEVEL = "debug" })
  child.lua([[require("duet").setup({ log_level = "error" }); require("duet.log").debug("from env")]])
  eq(#log_lines(), 1)
end

T["works from a fast event"] = function()
  start()
  child.lua([[
    local log = require("duet.log")
    local timer = vim.uv.new_timer()
    _G.done = false
    timer:start(0, 0, function()
      log.error("from timer")
      _G.done = true
      timer:close()
    end)
    vim.wait(1000, function() return _G.done end)
  ]])
  eq(#log_lines(), 1)
end

return T
