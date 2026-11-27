---@brief :checkhealth duet, with a registry of checks.
--- Built-in checks are registered at the bottom of this file. Feature checks are added
--- there too, with closures that `require` their module only when the check runs, so
--- lazy loading keeps working. Health checks may run short synchronous subprocesses
--- with a timeout. See |duet-health|.

local M = {}

---@class duet.HealthCheck
---@field name string
---@field fn fun()

---@type duet.HealthCheck[]
local checks = {}

---Register a health check. Checks run in registration order, each in its own section.
---Registering an existing name replaces that check in place.
---@param name string section title shown by :checkhealth
---@param fn fun() reports with vim.health.ok/info/warn/error
function M.register(name, fn)
  vim.validate("name", name, "string")
  vim.validate("fn", fn, "function")
  for _, check in ipairs(checks) do
    if check.name == name then
      check.fn = fn
      return
    end
  end
  checks[#checks + 1] = { name = name, fn = fn }
end

---Entry point for :checkhealth duet. A check that throws is reported as an error
---without hiding the others.
function M.check()
  for _, check in ipairs(checks) do
    vim.health.start(check.name)
    local ok, err = pcall(check.fn)
    if not ok then
      vim.health.error("check failed: " .. tostring(err))
    end
  end
end

local function check_core()
  local version = tostring(vim.version())
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. version)
  else
    vim.health.error("Neovim " .. version .. " is too old: duet requires Neovim >= 0.11")
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git found on PATH")
  else
    vim.health.error("git not found on PATH (needed for reviews)")
  end

  local config = require("duet.config")
  local opts = config.user_opts()
  if opts == nil then
    vim.health.ok("setup() not called, using the default config")
  else
    local ok, err, unknown = config.validate(opts)
    if ok then
      vim.health.ok("config is valid")
    else
      vim.health.error("invalid config: " .. err)
    end
    if #unknown > 0 then
      vim.health.warn("unknown option(s): " .. table.concat(unknown, ", "))
    end
  end

  vim.health.info("log file: " .. require("duet.log").path())
end

-- Built-in checks. Add feature checks here with a lazy require, e.g.:
--   M.register("agents", function() require("duet.agents").health() end)
M.register("duet", check_core)
M.register("agents", function()
  require("duet.agents").health()
end)
M.register("links", function()
  require("duet.links").health()
end)

return M
