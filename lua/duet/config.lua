---@brief Configuration: defaults, schema validation, merge and access.
--- Every option has an entry in `schema` (the source of truth for allowed keys) and,
--- when it has one, a default in `defaults`. See |duet-config|.

local M = {}

---@class duet.Config
---@field log_level string|integer log level name or vim.log.levels number
---@field agent string name of the default agent adapter
---@field agents table<string, table> per-agent overrides, keyed by agent name
---@field terminal table agent terminal options
---@field review table review options

---@type duet.Config
M.defaults = {
  log_level = "warn",
  agent = "claude",
  agents = {},
  terminal = {
    layout = "float",
    float = { width = 0.9, height = 0.9, border = "rounded" },
    split = { width = 0.4, height = 0.4 },
    close_on_exit = false,
    auto_insert = true,
    keys = { ["<C-q>"] = "normal_mode" },
  },
  review = {},
}

---@alias duet.config.Validator string|string[]|fun(v: any): boolean, string?

---@class duet.config.SchemaEntry
---@field type duet.config.Validator passed to vim.validate
---@field optional? boolean the value may be nil (the option has no default)
---@field open? boolean keys below this path are user-defined and not reported as unknown
---@field desc? string short description, reserved for generated docs

local function validate_level(v)
  return require("duet.log").parse_level(v) ~= nil
end

local function is_string_list(v)
  if type(v) ~= "table" or not vim.islist(v) then
    return false
  end
  for _, item in ipairs(v) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

local function validate_cmd(v)
  return is_string_list(v) and #v > 0
end

local function validate_string_map(v)
  if type(v) ~= "table" then
    return false
  end
  for key, value in pairs(v) do
    if type(key) ~= "string" or type(value) ~= "string" then
      return false
    end
  end
  return true
end

local function one_of(values)
  return function(v)
    return vim.tbl_contains(values, v)
  end
end

local function validate_size(v)
  return type(v) == "number" and v > 0
end

-- Border names differ between Neovim versions, so any string passes here; nvim_open_win
-- reports an unknown name when the terminal opens. A list must have 1, 2, 4 or 8 parts.
local function validate_border(v)
  if type(v) == "string" then
    return true
  end
  return is_string_list(v) and vim.tbl_contains({ 1, 2, 4, 8 }, #v)
end

local function validate_key_action(v)
  return v == false or (type(v) == "string" and vim.tbl_contains({ "normal_mode", "hide" }, v))
end

---Schema keyed by dotted path. A `*` segment matches any key, e.g. "agents.*.cmd".
---@type table<string, duet.config.SchemaEntry>
M.schema = {
  log_level = {
    type = validate_level,
    desc = 'one of "trace", "debug", "info", "warn", "error", "off", or a vim.log.levels number',
  },
  agent = { type = "string" },
  agents = { type = "table", open = true },
  ["agents.*"] = { type = "table" },
  ["agents.*.cmd"] = { type = validate_cmd, desc = "non-empty list of strings" },
  ["agents.*.args"] = { type = is_string_list, desc = "list of strings" },
  ["agents.*.env"] = { type = validate_string_map, desc = "table of string to string" },
  terminal = { type = "table" },
  ["terminal.layout"] = {
    type = one_of({ "float", "right", "left", "bottom" }),
    desc = '"float", "right", "left" or "bottom"',
  },
  ["terminal.float"] = { type = "table" },
  ["terminal.float.width"] = { type = validate_size, desc = "positive number" },
  ["terminal.float.height"] = { type = validate_size, desc = "positive number" },
  ["terminal.float.border"] = { type = validate_border, desc = "border name or list of 1, 2, 4 or 8 strings" },
  ["terminal.split"] = { type = "table" },
  ["terminal.split.width"] = { type = validate_size, desc = "positive number" },
  ["terminal.split.height"] = { type = validate_size, desc = "positive number" },
  ["terminal.close_on_exit"] = { type = "boolean" },
  ["terminal.auto_insert"] = { type = "boolean" },
  ["terminal.keys"] = { type = "table", open = true },
  ["terminal.keys.*"] = { type = validate_key_action, desc = '"normal_mode", "hide" or false' },
  review = { type = "table" },
}

---@type duet.Config|nil
local current
---@type table|nil
local last_user_opts

-- A non-empty list is a leaf value: it replaces, and its indexes are not option keys.
local function is_list(t)
  return type(t) == "table" and next(t) ~= nil and vim.islist(t)
end

local function is_dict(t)
  return type(t) == "table" and not is_list(t)
end

local function split(path)
  return vim.split(path, ".", { plain = true })
end

---Find the schema entry for an option path, trying exact keys before wildcards.
---The path is a list of segments rather than a dotted string, because user keys (such as
---the lhs in `terminal.keys`) may contain dots themselves.
---@param schema table<string, duet.config.SchemaEntry>
---@param segments string[]
---@return duet.config.SchemaEntry|nil
local function lookup(schema, segments)
  local exact = schema[table.concat(segments, ".")]
  if exact then
    return exact
  end
  for key, entry in pairs(schema) do
    local pattern = split(key)
    if #pattern == #segments then
      local match = true
      for i, seg in ipairs(pattern) do
        if seg ~= "*" and seg ~= segments[i] then
          match = false
          break
        end
      end
      if match then
        return entry
      end
    end
  end
  return nil
end

local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

---Validate user options against a schema without changing any state.
---@param opts any user options
---@param schema? table<string, duet.config.SchemaEntry> defaults to `M.schema`
---@return boolean ok
---@return string|nil err first validation error, prefixed with the dotted option path
---@return string[] unknown dotted paths of unknown options, sorted
function M.validate(opts, schema)
  schema = schema or M.schema
  local unknown = {}
  if type(opts) ~= "table" then
    return false, ("config: expected table, got %s"):format(type(opts)), unknown
  end

  local err
  local function walk(tbl, prefix, open)
    for _, key in ipairs(sorted_keys(tbl)) do
      local value = tbl[key]
      local segments = vim.list_extend(vim.deepcopy(prefix), { tostring(key) })
      local path = table.concat(segments, ".")
      local entry = lookup(schema, segments)
      if entry then
        local ok, msg = pcall(vim.validate, path, value, entry.type, entry.optional, entry.desc)
        if not ok then
          err = err or msg
        end
      elseif not open then
        unknown[#unknown + 1] = path
      end
      if is_dict(value) and (entry or open) then
        walk(value, segments, open or (entry ~= nil and entry.open == true))
      end
    end
  end
  walk(opts, {}, false)

  if err then
    return false, err, unknown
  end
  return true, nil, unknown
end

---Merge `src` into `dst` in place: dictionaries merge deeply, lists and scalars replace.
---@param dst table
---@param src table
---@return table dst
local function merge(dst, src)
  for key, value in pairs(src) do
    if is_dict(value) and is_dict(dst[key]) then
      merge(dst[key], value)
    else
      dst[key] = vim.deepcopy(value)
    end
  end
  return dst
end

---Validate and apply user options over the defaults. Each call starts from the
---defaults again, so calling it twice does not stack. On a validation error the
---previous config is kept and an error is shown. Unknown options produce one warning.
---@param opts? table user options
---@return boolean|nil ok
---@return string|nil err
function M.setup(opts)
  local util = require("duet.util")
  if opts == nil then
    opts = {}
  end
  last_user_opts = vim.deepcopy(opts)
  local ok, err, unknown = M.validate(opts)
  if not ok then
    util.notify("invalid config: " .. err, vim.log.levels.ERROR)
    return nil, err
  end
  if #unknown > 0 then
    util.notify("unknown option(s): " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  current = merge(vim.deepcopy(M.defaults), opts)
  return true
end

---Current configuration. Read-only by contract; returns the defaults if setup() never ran.
---@return duet.Config
function M.get()
  if not current then
    current = vim.deepcopy(M.defaults)
  end
  return current
end

---The options last passed to setup(), valid or not, or nil. Used by :checkhealth.
---@return table|nil
function M.user_opts()
  return last_user_opts
end

return M
