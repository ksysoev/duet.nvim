---@brief Reload buffers when the agent changes their files on disk.
--- While at least one agent session runs, the directory of every listed file buffer is
--- watched with |uv.new_fs_event()|. A change is debounced, then |:checktime| runs for the
--- buffers in the directories that changed: unchanged buffers reload (with 'autoread'),
--- buffers with unsaved changes get the usual W12 prompt. Directories are watched rather
--- than files, because a write to a temporary file renamed over the original leaves a
--- file watch on the old inode. See |duet-watch|.

local M = {}

---@class duet.watch.State
---@field active boolean watching: the autocmds are set and directories are watched
---@field dirs table<string, uv.uv_fs_event_t> watcher by directory
---@field pending table<string, true> directories changed since the last check
---@field timer uv.uv_timer_t|nil debounce timer while active
---@field augroup integer|nil autocmds while active
---@field saved_autoread boolean|nil global 'autoread' before duet turned it on, nil if untouched
---@field sync_scheduled boolean a sync() is scheduled
local state = {
  active = false,
  dirs = {},
  pending = {},
  timer = nil,
  augroup = nil,
  saved_autoread = nil,
  sync_scheduled = false,
}

local function config()
  return require("duet.config").get().watch
end

---Whether a buffer with this name, 'buftype' and 'buflisted' is a file duet watches:
---a listed, normal buffer with a name that is not a URI (`duet://`, `oil://`, …).
---@param name string buffer name
---@param buftype string
---@param listed boolean
---@return boolean
function M.watchable(name, buftype, listed)
  return listed and buftype == "" and name ~= "" and not name:match("^%a[%w+.-]*://")
end

---The directory to watch for a buffer with this name, 'buftype' and 'buflisted', or nil
---if it is not watchable. Does not check that the directory exists.
---@param name string buffer name
---@param buftype string
---@param listed boolean
---@return string|nil dir absolute, normalized
function M.dir_of(name, buftype, listed)
  if not M.watchable(name, buftype, listed) then
    return nil
  end
  return vim.fs.dirname(vim.fs.normalize(vim.fs.abspath(name)))
end

---The directory to watch for `buf`, or nil.
---@param buf integer
---@return string|nil
local function buffer_dir(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return M.dir_of(vim.api.nvim_buf_get_name(buf), vim.bo[buf].buftype, vim.bo[buf].buflisted)
end

---@param path string
---@return boolean
local function is_directory(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---@param handle uv.uv_fs_event_t
local function close_handle(handle)
  handle:stop()
  if not handle:is_closing() then
    handle:close()
  end
end

---Restart the debounce timer: check the pending directories once changes stop.
---Safe in a fast event (the fs_event callback).
local function debounce(flush)
  if not state.timer then
    return
  end
  state.timer:stop()
  state.timer:start(config().debounce_ms, 0, function()
    vim.schedule(flush)
  end)
end

-- Modes in which :checktime could not run or its prompt would get in the way: the
-- command line, a hit-enter or more prompt, a shell command.
local function busy()
  local mode = vim.api.nvim_get_mode()
  return mode.blocking or mode.mode:match("^[cr!]") ~= nil
end

local flush

---Run :checktime for the watched buffers in `dirs`, or all watched buffers if nil.
---Buffers that can't be checked now (e.g. under textlock) stay pending and are checked
---after another debounce.
---@param dirs? table<string, true>
function M.checktime(dirs)
  local retry = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local dir = buffer_dir(buf)
    if dir and (dirs == nil or dirs[dir]) and vim.api.nvim_buf_is_loaded(buf) then
      local ok, err = pcall(vim.cmd.checktime, buf)
      if not ok then
        require("duet.log").debug("watch: checktime %d failed, retrying: %s", buf, err)
        state.pending[dir] = true
        retry = true
      end
    end
  end
  if retry then
    debounce(flush)
  end
end

---Check the directories that changed, unless the editor is busy: then wait again.
flush = function()
  if not state.active or next(state.pending) == nil then
    return
  end
  if busy() then
    debounce(flush)
    return
  end
  local dirs = state.pending
  state.pending = {}
  M.checktime(dirs)
end

local schedule_sync

---Start watching `dir`. A failure (e.g. the inotify limit) is logged: the TermLeave and
---FocusGained checks still cover the directory's buffers.
---@param dir string
local function watch(dir)
  local handle, new_err = vim.uv.new_fs_event()
  if not handle then
    require("duet.log").warn("watch: cannot create a watcher for %s: %s", dir, new_err)
    return
  end
  local ok, err = handle:start(dir, {}, function(event_err)
    if event_err then
      -- E.g. the directory is gone: drop the watcher, sync() adds it back if it returns.
      vim.schedule(function()
        if state.dirs[dir] == handle then
          state.dirs[dir] = nil
          close_handle(handle)
          require("duet.log").debug("watch: stopped watching %s: %s", dir, event_err)
          schedule_sync()
        end
      end)
      return
    end
    state.pending[dir] = true
    debounce(flush)
  end)
  if not ok then
    close_handle(handle)
    require("duet.log").warn("watch: cannot watch %s: %s", dir, err)
    return
  end
  state.dirs[dir] = handle
  require("duet.log").trace("watch: watching %s", dir)
end

---Watch the directories of the listed file buffers, and only those.
function M.sync()
  state.sync_scheduled = false
  if not state.active then
    return
  end
  local want = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local dir = buffer_dir(buf)
    if dir and want[dir] == nil then
      want[dir] = is_directory(dir)
    end
  end
  for dir, handle in pairs(state.dirs) do
    if not want[dir] then
      state.dirs[dir] = nil
      close_handle(handle)
      require("duet.log").trace("watch: stopped watching %s", dir)
    end
  end
  for dir, exists in pairs(want) do
    if exists and not state.dirs[dir] then
      watch(dir)
    end
  end
end

---Sync once the current event is done: BufDelete and BufWipeout fire while the buffer
---is still listed. Several calls in a row sync once.
schedule_sync = function()
  if state.sync_scheduled then
    return
  end
  state.sync_scheduled = true
  vim.schedule(M.sync)
end

local function set_autocmds()
  local group = vim.api.nvim_create_augroup("duet.watch", { clear = true })
  state.augroup = group
  vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout", "BufFilePost", "BufWritePost" }, {
    group = group,
    desc = "duet: watch the directories of file buffers",
    callback = schedule_sync,
  })
  vim.api.nvim_create_autocmd("TermLeave", {
    group = group,
    desc = "duet: check for files the agent changed",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "duet_terminal" then
        vim.schedule(function()
          M.checktime()
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "duet: check for files the agent changed",
    callback = function()
      vim.schedule(function()
        M.checktime()
      end)
    end,
  })
end

local function start()
  state.active = true
  state.timer = assert(vim.uv.new_timer())
  set_autocmds()
  if config().autoread and not vim.go.autoread then
    state.saved_autoread = vim.go.autoread
    vim.go.autoread = true
  end
  require("duet.log").debug("watch: started")
  M.sync()
end

---Stop watching: close every watcher and the timer, remove the autocmds and put
---'autoread' back. Safe to call when not watching.
function M.stop()
  if not state.active then
    return
  end
  state.active = false
  for dir, handle in pairs(state.dirs) do
    state.dirs[dir] = nil
    close_handle(handle)
  end
  state.pending = {}
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  -- Leave 'autoread' alone if it was turned off since duet turned it on.
  if state.saved_autoread ~= nil and vim.go.autoread then
    vim.go.autoread = state.saved_autoread
  end
  state.saved_autoread = nil
  require("duet.log").debug("watch: stopped")
end

---Watch while `watch.enabled` is set and an agent session runs; stop otherwise. Called by
---duet.terminal when a session starts, exits or stops.
function M.refresh()
  local running = false
  if config().enabled then
    for _, session in ipairs(require("duet.terminal").list()) do
      if session:is_running() then
        running = true
        break
      end
    end
  end
  if running and not state.active then
    start()
  elseif not running and state.active then
    M.stop()
  end
end

---Internal state, for tests.
---@return { active: boolean, dirs: string[], augroup: integer|nil, timer: boolean, saved_autoread: boolean|nil }
function M._state()
  local dirs = vim.tbl_keys(state.dirs)
  table.sort(dirs)
  return {
    active = state.active,
    dirs = dirs,
    augroup = state.augroup,
    timer = state.timer ~= nil,
    saved_autoread = state.saved_autoread,
  }
end

return M
