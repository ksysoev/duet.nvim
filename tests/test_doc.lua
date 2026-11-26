local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["helptags build without errors"] = function()
  -- Work on a copy so the repo's doc/ doesn't get a tags file.
  local dir = h.tmp_dir()
  vim.fn.writefile(vim.fn.readfile("doc/duet.txt"), dir .. "/duet.txt")
  MiniTest.expect.no_error(function()
    vim.cmd("helptags " .. vim.fn.fnameescape(dir))
  end)
  local tags = vim.fn.readfile(dir .. "/tags")
  local names = vim.tbl_map(function(line)
    return line:match("^([^\t]+)")
  end, tags)
  for _, tag in ipairs({
    "duet",
    ":Duet",
    "duet-config",
    "duet-health",
    "duet.setup()",
    "duet-agents",
    "duet.agents.get()",
    "duet-terminal",
    ":Duet-toggle",
    "duet-config-terminal-layout",
    "duet-config-terminal-split",
    "duet.terminal.current()",
    "duet-send",
    ":Duet-send",
    ":Duet-prompt",
    "duet.send()",
    "duet-config-send",
    "duet.terminal.ensure()",
    "duet.terminal.target()",
    "duet-context",
    "duet-context-providers",
    "duet-context-ctx",
    ":Duet-ask",
    "duet-config-prompts",
    "duet.ask()",
    "duet.render()",
    "duet.context.register()",
  }) do
    eq({ tag, vim.tbl_contains(names, tag) }, { tag, true })
  end
end

return T
