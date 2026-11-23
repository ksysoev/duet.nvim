---@brief File logger writing to stdpath("log")/duet.log.
--- Shared with the bridge processes (`nvim -l bridge/*.lua`), so it must not depend on
--- UI code or other duet modules at load time, and it never writes to stdout.
--- The level comes from $DUET_LOG_LEVEL, else `config.log_level`, else "warn".

local M = {}

---Log levels, numerically equal to vim.log.levels.
---@type table<string, integer>
M.levels = { trace = 0, debug = 1, info = 2, warn = 3, error = 4, off = 5 }

local LEVEL_NAMES = { [0] = "TRACE", [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
local DEFAULT_LEVEL = M.levels.warn

-- stdpath() is not allowed in fast events, so resolve the path once, at load time.
local log_dir = vim.fn.stdpath("log") --[[@as string]]
local log_path = vim.fs.joinpath(log_dir, "duet.log")
local env_level = os.getenv("DUET_LOG_LEVEL")
local tag = "parent"

---Convert a level name (case-insensitive) or number to a number.
---@param level any
---@return integer|nil
function M.parse_level(level)
  if type(level) == "number" then
    if level >= M.levels.trace and level <= M.levels.off and level % 1 == 0 then
      return level
    end
    return nil
  end
  if type(level) == "string" then
    return M.levels[level:lower()]
  end
  return nil
end

local function current_level()
  local from_env = env_level and M.parse_level(env_level)
  if from_env then
    return from_env
  end
  local ok, config = pcall(require, "duet.config")
  if ok then
    local level = M.parse_level(config.get().log_level)
    if level then
      return level
    end
  end
  return DEFAULT_LEVEL
end

local function format(fmt, ...)
  local args = { ... }
  for i = 1, select("#", ...) do
    if type(args[i]) == "table" then
      args[i] = vim.inspect(args[i], { newline = " ", indent = "" })
    end
  end
  local ok, msg = pcall(string.format, tostring(fmt), unpack(args, 1, select("#", ...)))
  if not ok then
    return tostring(fmt)
  end
  return msg
end

-- vim.fn.mkdir() is not allowed in fast events; vim.uv.fs_mkdir is.
local function mkdir_p(dir)
  if vim.uv.fs_stat(dir) then
    return
  end
  local parent = vim.fs.dirname(dir)
  if parent and parent ~= dir then
    mkdir_p(parent)
  end
  vim.uv.fs_mkdir(dir, 493) -- 0755
end

local function write(level, fmt, ...)
  if level < current_level() then
    return
  end
  local line =
    string.format("%s %-5s [%s] %s\n", os.date("%Y-%m-%dT%H:%M:%S"), LEVEL_NAMES[level], tag, format(fmt, ...))
  -- One write per line in append mode, so lines from several processes don't interleave.
  local f = io.open(log_path, "a")
  if not f then
    mkdir_p(log_dir)
    f = io.open(log_path, "a")
  end
  if f then
    f:write(line)
    f:close()
  end
end

---Path of the log file.
---@return string
function M.path()
  return log_path
end

---Set the process tag written on each line (default "parent"), e.g. "bridge:<pid>".
---@param new_tag string
function M.set_tag(new_tag)
  tag = new_tag
end

---Log at TRACE level. `fmt` is a string.format pattern; table args are inspected.
---@param fmt string
---@param ... any
function M.trace(fmt, ...)
  write(M.levels.trace, fmt, ...)
end

---Log at DEBUG level.
---@param fmt string
---@param ... any
function M.debug(fmt, ...)
  write(M.levels.debug, fmt, ...)
end

---Log at INFO level.
---@param fmt string
---@param ... any
function M.info(fmt, ...)
  write(M.levels.info, fmt, ...)
end

---Log at WARN level.
---@param fmt string
---@param ... any
function M.warn(fmt, ...)
  write(M.levels.warn, fmt, ...)
end

---Log at ERROR level.
---@param fmt string
---@param ... any
function M.error(fmt, ...)
  write(M.levels.error, fmt, ...)
end

return M
