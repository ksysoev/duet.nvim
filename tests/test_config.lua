local MiniTest = require("mini.test")
local h = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local capture

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.reset_modules()
      capture = h.capture_notify()
    end,
    post_case = function()
      capture.restore()
    end,
  },
})

local function config()
  return require("duet.config")
end

T["get() before setup() returns the defaults"] = function()
  eq(config().get(), config().defaults)
end

T["merge"] = MiniTest.new_set()

local merge_cases = {
  {
    name = "nested table merges",
    opts = { terminal = { layout = "right", float = { width = 0.5 } }, review = { a = { b = 1 } } },
    check = function(c)
      eq(c.terminal.layout, "right")
      eq(c.terminal.float, { width = 0.5, height = 0.9, border = "rounded" })
      eq(c.terminal.keys, {
        ["<C-q>"] = "normal_mode",
        gf = "open_link",
        ["<CR>"] = "open_link",
        ["]l"] = "next_link",
        ["[l"] = "prev_link",
      })
      eq(c.review, { a = { b = 1 } })
      eq(c.agent, "claude")
    end,
  },
  {
    name = "terminal keys replace a default spelled differently",
    opts = { terminal = { keys = { ["<cr>"] = false, ["<C-Q>"] = "hide" } } },
    check = function(c)
      eq(c.terminal.keys, {
        ["<C-Q>"] = "hide",
        ["<cr>"] = false,
        gf = "open_link",
        ["]l"] = "next_link",
        ["[l"] = "prev_link",
      })
    end,
  },
  {
    name = "terminal keys spelled like a default replace it",
    opts = { terminal = { keys = { ["<CR>"] = "hide" } } },
    check = function(c)
      eq(c.terminal.keys["<CR>"], "hide")
    end,
  },
  {
    name = "scalar overrides",
    opts = { agent = "other", log_level = "debug" },
    check = function(c)
      eq(c.agent, "other")
      eq(c.log_level, "debug")
    end,
  },
  {
    name = "list replaces list",
    setup_first = { agents = { x = { cmd = { "claude", "--a", "--b" } } } },
    opts = { agents = { x = { cmd = { "x" } } } },
    check = function(c)
      eq(c.agents.x.cmd, { "x" })
    end,
  },
  {
    name = "a list option replaces the default list",
    opts = { links = { replace_filetypes = { "starter" } } },
    check = function(c)
      eq(c.links.replace_filetypes, { "starter" })
      eq(c.links.debounce_ms, 100)
    end,
  },
  {
    name = "an empty list replaces the default list",
    opts = { links = { replace_filetypes = {} } },
    check = function(c)
      eq(c.links.replace_filetypes, {})
    end,
  },
  {
    name = "setup() twice does not stack",
    setup_first = { review = { a = 1 } },
    opts = { review = { b = 2 } },
    check = function(c)
      eq(c.review, { b = 2 })
    end,
  },
  {
    name = "setup(nil) gives the defaults",
    opts = nil,
    check = function(c)
      eq(c, require("duet.config").defaults)
    end,
  },
  {
    name = "setup({}) gives the defaults",
    opts = {},
    check = function(c)
      eq(c, require("duet.config").defaults)
    end,
  },
}

for _, case in ipairs(merge_cases) do
  T["merge"][case.name] = function()
    if case.setup_first then
      eq(config().setup(case.setup_first), true)
    end
    eq(config().setup(case.opts), true)
    -- Merging is independent of unknown-key warnings, which are tested below.
    case.check(config().get())
  end
end

T["merge"]["does not alias user tables or mutate the defaults"] = function()
  local opts = { agents = { x = { cmd = { "a" } } } }
  config().setup(opts)
  opts.agents.x.cmd[1] = "changed"
  eq(config().get().agents.x.cmd, { "a" })
  eq(config().defaults.agents, {})
end

T["validation error"] = MiniTest.new_set({
  parametrize = {
    { "table option given a string", { terminal = "x" }, "terminal: expected table, got string" },
    { "unknown level name", { log_level = "loud" }, "^log_level: expected .* got loud$" },
    { "out-of-range level number", { log_level = 42 }, "^log_level: expected .* got 42$" },
    { "string option given a number", { agent = 1 }, "agent: expected string, got number" },
    { "non-table opts", "str", "config: expected table, got string" },
    { "agent entry not a table", { agents = { claude = "x" } }, "^agents.claude: expected table" },
    { "agent cmd as a string", { agents = { claude = { cmd = "claude" } } }, "^agents.claude.cmd: expected" },
    { "agent cmd empty", { agents = { claude = { cmd = {} } } }, "^agents.claude.cmd: expected" },
    { "agent args with a number", { agents = { claude = { args = { 1 } } } }, "^agents.claude.args: expected" },
    { "agent env with a number", { agents = { claude = { env = { A = 1 } } } }, "^agents.claude.env: expected" },
    { "unknown layout", { terminal = { layout = "top" } }, "^terminal.layout: expected" },
    { "zero float width", { terminal = { float = { width = 0 } } }, "^terminal.float.width: expected" },
    { "split height as a string", { terminal = { split = { height = "1" } } }, "^terminal.split.height: expected" },
    {
      "negative min_code_width",
      { terminal = { split = { min_code_width = -1 } } },
      "^terminal.split.min_code_width: expected",
    },
    {
      "infinite min_code_width",
      { terminal = { split = { min_code_width = math.huge } } },
      "^terminal.split.min_code_width: expected",
    },
    {
      "fractional min_code_height",
      { terminal = { split = { min_code_height = 0.5 } } },
      "^terminal.split.min_code_height: expected",
    },
    { "border as a number", { terminal = { float = { border = 1 } } }, "^terminal.float.border: expected" },
    {
      "border list of 3",
      { terminal = { float = { border = { "a", "b", "c" } } } },
      "^terminal.float.border: expected",
    },
    { "close_on_exit unknown", { terminal = { close_on_exit = "yes" } }, "^terminal.close_on_exit: expected" },
    { "close_on_exit as a boolean", { terminal = { close_on_exit = true } }, "^terminal.close_on_exit: expected" },
    { "unknown key action", { terminal = { keys = { ["<C-x>"] = "nope" } } }, "^terminal.keys.<C%-x>: expected" },
    { "negative submit delay", { send = { submit_delay_ms = -1 } }, "^send.submit_delay_ms: expected" },
    { "fractional ready timeout", { send = { ready_timeout_ms = 1.5 } }, "^send.ready_timeout_ms: expected" },
    {
      "replace_filetypes as a string",
      { links = { replace_filetypes = "alpha" } },
      "^links.replace_filetypes: expected",
    },
    {
      "replace_filetypes with a number",
      { links = { replace_filetypes = { "alpha", 1 } } },
      "^links.replace_filetypes: expected",
    },
    { "watch as a boolean", { watch = false }, "^watch: expected table" },
    { "watch enabled as a string", { watch = { enabled = "yes" } }, "^watch.enabled: expected" },
    { "negative watch debounce", { watch = { debounce_ms = -1 } }, "^watch.debounce_ms: expected" },
    { "watch autoread as a number", { watch = { autoread = 1 } }, "^watch.autoread: expected" },
    { "prompts as a string", { prompts = "x" }, "^prompts: expected table of prompts" },
    { "prompt name with a space", { prompts = { ["write tests"] = "x" } }, "^prompts: expected table of prompts" },
    { "prompt name with a dot", { prompts = { ["a.b"] = "x" } }, "^prompts: expected table of prompts" },
    { "prompt as a number", { prompts = { fix = 1 } }, "^prompts.fix: expected" },
    { "prompt as true", { prompts = { fix = true } }, "^prompts.fix: expected" },
    {
      "key action under a dotted lhs",
      { terminal = { keys = { ["<M-.>"] = "hid" } } },
      "^terminal.keys.<M%-.>: expected",
    },
  },
})

T["validation error"]["%s"] = function(_, opts, pattern)
  config().setup({ agent = "previous" })
  local ok, err = config().setup(opts)
  eq(ok, nil)
  eq(err:match(pattern) ~= nil, true)
  -- The previous config is kept.
  eq(config().get().agent, "previous")
  eq(#capture.messages, 1)
  eq(capture.messages[1].level, vim.log.levels.ERROR)
  eq(vim.startswith(capture.messages[1].msg, "[duet] invalid config: "), true)
end

T["unknown keys"] = MiniTest.new_set({
  parametrize = {
    { "top-level key", { foo = 1 }, "foo" },
    { "nested key", { terminal = { bar = 1 } }, "terminal.bar" },
    { "several keys in one warning", { foo = 1, bar = { baz = 1 } }, "bar, foo" },
    { "key inside an open map", { agents = { anything = { cmd = { "x" } } } }, nil },
    { "list values are not keys", { agents = { x = { args = { "a", "b" } } } }, nil },
    { "agent env keys are not options", { agents = { x = { env = { FOO = "1" }, args = {} } } }, nil },
    { "terminal keys are not options", { terminal = { keys = { ["<C-q>"] = false, ["<C-x>"] = "hide" } } }, nil },
    { "dotted terminal keys are not options", { terminal = { keys = { ["<M-.>"] = "hide" } } }, nil },
    { "prompt names are not options", { prompts = { mine = "Do {file}", explain = false } }, nil },
    { "prompt names with - and _", { prompts = { ["write-tests"] = "x", fix_all = "y" } }, nil },
  },
})

T["unknown keys"]["%s"] = function(_, opts, expected)
  eq(config().setup(opts), true)
  if expected == nil then
    eq(capture.messages, {})
  else
    eq(capture.messages, { { msg = "[duet] unknown option(s): " .. expected, level = vim.log.levels.WARN } })
  end
end

T["prompts merge with the defaults"] = function()
  eq(config().setup({ prompts = { tests = "Test {file}", fix = false } }), true)
  eq(
    config().get().prompts,
    { explain = "Explain {this}", fix = false, review = "Review {file}", tests = "Test {file}" }
  )
end

T["schema"] = MiniTest.new_set()

local test_schema = {
  agents = { type = "table", open = true },
  ["agents.*.cmd"] = { type = "table", optional = true },
  terminal = { type = "table" },
  ["terminal.layout"] = { type = "string" },
}

local schema_cases = {
  { name = "wildcard validates per-entry fields", opts = { agents = { a = { cmd = "x" } } }, err = "agents.a.cmd" },
  { name = "wildcard accepts a valid value", opts = { agents = { a = { cmd = { "x" } } } }, unknown = {} },
  { name = "open map allows any key", opts = { agents = { a = { other = 1 } } }, unknown = {} },
  { name = "known sub-key validates", opts = { terminal = { layout = 1 } }, err = "terminal.layout" },
  { name = "unknown sub-key is reported", opts = { terminal = { size = 1 } }, unknown = { "terminal.size" } },
}

for _, case in ipairs(schema_cases) do
  T["schema"][case.name] = function()
    local ok, err, unknown = config().validate(case.opts, test_schema)
    if case.err then
      eq(ok, false)
      eq(vim.startswith(err, case.err .. ":"), true)
    else
      eq({ ok, err, unknown }, { true, nil, case.unknown })
    end
  end
end

T["user_opts() records the last options"] = function()
  eq(config().user_opts(), nil)
  config().setup({ foo = 1 })
  eq(config().user_opts(), { foo = 1 })
end

return T
