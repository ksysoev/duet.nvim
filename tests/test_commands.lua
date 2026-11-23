local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local capture, calls, commands

local function fake(name, complete)
  commands.register(name, {
    desc = "fake",
    impl = function(args, opts)
      table.insert(calls, { name = name, args = args, opts = opts })
    end,
    complete = complete,
  })
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.reset_modules()
      capture = h.capture_notify()
      calls = {}
      commands = require("duet.commands")
      vim.v.errmsg = ""
    end,
    post_case = function()
      capture.restore()
    end,
  },
})

T["run()"] = MiniTest.new_set()

T["run()"]["routes args"] = function()
  fake("fake")
  vim.cmd("Duet fake a b")
  eq(#calls, 1)
  eq(calls[1].args, { "a", "b" })
  eq(calls[1].opts.rest, "a b")
end

T["run()"]["keeps the raw text in opts.rest"] = function()
  fake("fake")
  vim.cmd([[Duet fake  a   "b c"]])
  eq(calls[1].opts.rest, [[ a   "b c"]])
end

T["run()"]["passes range and bang"] = function()
  fake("fake")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "1", "2", "3", "4", "5" })
  vim.cmd("2,3Duet! fake")
  local opts = calls[1].opts
  eq({ opts.range, opts.line1, opts.line2, opts.bang }, { 2, 2, 3, true })
  eq(calls[1].args, {})
  eq(opts.rest, "")
end

T["run()"]["reports an unknown subcommand"] = function()
  fake("fake")
  vim.cmd("Duet nope")
  eq(capture.messages, {
    { msg = "[duet] unknown subcommand 'nope'. Available: fake", level = vim.log.levels.ERROR },
  })
end

T["run()"]["shows usage with no args and no toggle"] = function()
  fake("fake")
  vim.cmd("Duet")
  eq(capture.messages, {
    { msg = "[duet] usage: :Duet <subcommand> [args]. Subcommands: fake", level = vim.log.levels.INFO },
  })
  eq(vim.v.errmsg, "")
end

T["run()"]["runs toggle with no args"] = function()
  fake("toggle")
  vim.cmd("Duet")
  eq(#calls, 1)
  eq(calls[1].name, "toggle")
  eq(calls[1].args, {})
end

T["run()"]["catches an impl that throws"] = function()
  commands.register("boom", {
    impl = function()
      error("kaboom")
    end,
  })
  vim.cmd("Duet boom")
  eq(#capture.messages, 1)
  eq(capture.messages[1].level, vim.log.levels.ERROR)
  eq(capture.messages[1].msg:match("^%[duet%] boom: .*kaboom$") ~= nil, true)
end

T["run()"]["shows the error an impl returns"] = function()
  commands.register("fail", {
    impl = function()
      return nil, "fail: went wrong"
    end,
  })
  vim.cmd("Duet fail")
  eq(capture.messages, { { msg = "[duet] fail: went wrong", level = vim.log.levels.ERROR } })
end

T["register()"] = MiniTest.new_set({
  parametrize = {
    { "missing impl", "x", {} },
    { "non-function complete", "x", { impl = function() end, complete = "no" } },
    { "empty name", "", { impl = function() end } },
    { "name with a space", "a b", { impl = function() end } },
    { "non-table spec", "x", "spec" },
  },
})

T["register()"]["throws on %s"] = function(_, name, spec)
  MiniTest.expect.error(function()
    commands.register(name, spec)
  end)
end

T["complete()"] = MiniTest.new_set()

local complete_cases = {
  { name = "all names after the command", line = "Duet ", lead = "", expected = { "fake", "fun", "toggle" } },
  { name = "filters by prefix", line = "Duet f", lead = "f", expected = { "fake", "fun" } },
  { name = "after a visual range", line = "'<,'>Duet fa", lead = "fa", expected = { "fake" } },
  { name = "after a numeric range", line = "5,10Duet fa", lead = "fa", expected = { "fake" } },
  { name = "with an abbreviated command", line = "Du fa", lead = "fa", expected = { "fake" } },
  { name = "after a bang", line = "Duet! fa", lead = "fa", expected = { "fake" } },
  { name = "after a modifier", line = "silent Duet fa", lead = "fa", expected = { "fake" } },
  { name = "unknown subcommand", line = "Duet nope ", lead = "", expected = {} },
  { name = "subcommand without completion", line = "Duet toggle ", lead = "", expected = {} },
  { name = "first argument", line = "Duet fake ", lead = "", expected = { "args=", "lead=" } },
  { name = "second argument", line = "Duet fake x y", lead = "y", expected = { "args=x", "lead=y" } },
}

for _, case in ipairs(complete_cases) do
  T["complete()"][case.name] = function()
    fake("fake", function(lead, args)
      return { "args=" .. table.concat(args, ","), "lead=" .. lead }
    end)
    fake("fun")
    fake("toggle")
    eq(commands.complete(case.lead, case.line, #case.line), case.expected)
  end
end

T["complete()"]["only reads the cmdline up to the cursor"] = function()
  fake("fake")
  eq(commands.complete("fa", "Duet fa more", 7), { "fake" })
end

T["complete()"]["works through getcompletion()"] = function()
  fake("fake")
  eq(vim.fn.getcompletion("Duet ", "cmdline"), { "fake" })
end

return T
