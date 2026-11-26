---@brief Reload buffers when the agent changes their files on disk.
--- While at least one agent session runs, the directory of every listed file buffer is
--- watched with |uv.new_fs_event()|. A change is debounced, then |:checktime| runs for the
--- buffers in the directories that changed: unchanged buffers reload (with 'autoread'),
--- buffers with unsaved changes get the usual W12 prompt. Directories are watched rather
--- than files, because a write to a temporary file renamed over the original leaves a
--- file watch on the old inode. See |duet-watch|.

local M = {}

---@class duet.watch.Watcher
---@field handle uv.uv_fs_event_t
---@field dev integer device of the directory when the watch started
---@field ino integer inode of the directory when the watch started
---@field broken boolean the watcher reported an error

---@class duet.watch.State
---@field active boolean watching: the autocmds are set and directories are watched
---@field dirs table<string, duet.watch.Watcher> watcher by directory
---@field failed table<string, true> directories that could not be watched, not tried again
---@field missing table<string, true> directories of buffers that do not exist (yet)
---@field existed table<integer, boolean> whether each watched buffer's file existed when last seen
---@field pending table<string, true> directories to check
---@field timer uv.uv_timer_t|nil debounce timer while active
---@field deadline integer|nil loop time (ms) by which the pending directories are checked
---@field poll uv.uv_timer_t|nil polls the missing directories while there are any
---@field augroup integer|nil autocmds while active
---@field saved_autoread boolean|nil global 'autoread' before duet turned it on, nil if untouched
---@field sync_scheduled boolean a sync() is scheduled
local state = {
  active = false,
  dirs = {},
  failed = {},
  missing = {},
  existed = {},
  pending = {},
  timer = nil,
  deadline = nil,
  poll = nil,
  augroup = nil,
  saved_autoread = nil,
  sync_scheduled = false,
}

-- Errors after which :checktime can run later: not allowed here (E523), textlock (E565),
-- the command-line window (E11). Others are reported and not retried.
local TRANSIENT_ERRORS = { "E11:", "E523:", "E565:" }

-- Changes that keep coming (a log file written every few ms) delay the check by at most
-- this long, or debounce_ms if that is longer, so other directories still reload.
local MAX_WAIT_MS = 1000
-- Shortest wait before trying a check again that could not run (busy editor, textlock),
-- so a debounce_ms of 0 does not spin.
local RETRY_MS = 100
-- How often directories that buffers need but that do not exist are looked for again.
local POLL_MS = 1000

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

---Whether a check in `mode` (from nvim_get_mode()) must wait: in the command line or
---its window, at a hit-enter or more prompt, or during a shell command, :checktime fails
---or its prompt gets in the way.
---@param mode { mode: string, blocking: boolean }
---@param cmdwin boolean the command-line window is open
---@return boolean
function M.busy(mode, cmdwin)
  return mode.blocking or cmdwin or mode.mode:match("^[cr!]") ~= nil
end

---Whether the user is typing in `mode`: in a terminal, Insert or Replace mode, or after
---an operator. A W12 or W11 prompt there would take the next key typed as its answer.
---@param mode string from nvim_get_mode()
---@return boolean
function M.typing(mode)
  return mode:match("^[tiR]") ~= nil or mode:match("^no") ~= nil
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

---@param buf integer
---@return boolean
local function file_exists(buf)
  return vim.uv.fs_stat(vim.api.nvim_buf_get_name(buf)) ~= nil
end

---Whether :checktime on a changed `buf` would ask rather than reload it: it has unsaved
---changes (W12), its file was created since it was last seen (W13, even with
---'autoread'), or 'autoread' is off for it (W11).
---@param buf integer
---@return boolean
local function would_prompt(buf)
  if vim.bo[buf].modified then
    return true
  end
  if state.existed[buf] == false and file_exists(buf) then
    return true
  end
  -- 'autoread' is global-local: the buffer's value is nil unless set with :setlocal.
  local autoread = vim.bo[buf].autoread
  if autoread == nil then
    autoread = vim.go.autoread
  end
  return not autoread
end

---@param err string
---@return boolean
local function is_transient(err)
  for _, code in ipairs(TRANSIENT_ERRORS) do
    if err:find(code, 1, true) then
      return true
    end
  end
  return false
end

---@param path string
---@return uv.fs_stat.result|nil
local function dir_stat(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return stat
  end
  return nil
end

---@param handle uv.uv_fs_event_t
local function close_handle(handle)
  handle:stop()
  if not handle:is_closing() then
    handle:close()
  end
end

---@param dir string
local function unwatch(dir)
  local watcher = state.dirs[dir]
  if watcher then
    state.dirs[dir] = nil
    close_handle(watcher.handle)
    require("duet.log").trace("watch: stopped watching %s", dir)
  end
end

---Flush in `delay` ms.
---@param delay integer
local function arm(delay)
  if not state.timer then
    return
  end
  state.timer:stop()
  state.timer:start(delay, 0, function()
    vim.schedule(M.flush)
  end)
end

---Restart the debounce timer: check the pending directories once changes stop, but no
---later than the deadline set by the first change. Safe in a fast event.
local function debounce()
  local wait = config().debounce_ms
  local now = vim.uv.now()
  if not state.deadline then
    state.deadline = now + math.max(wait, MAX_WAIT_MS)
  end
  arm(math.max(0, math.min(wait, state.deadline - now)))
end

---Try a check that could not run again later.
local function retry()
  arm(math.max(config().debounce_ms, RETRY_MS))
end

---Start watching `dir`. A failure (e.g. the inotify limit) is logged once: the directory
---is not tried again until watching restarts, and the TermLeave and FocusGained checks
---still cover its buffers.
---@param dir string
---@param stat uv.fs_stat.result
local function watch(dir, stat)
  local log = require("duet.log")
  local handle, new_err = vim.uv.new_fs_event()
  if not handle then
    state.failed[dir] = true
    log.warn("watch: cannot create a watcher for %s: %s", dir, new_err)
    return
  end
  ---@type duet.watch.Watcher
  local watcher = { handle = handle, dev = stat.dev, ino = stat.ino, broken = false }
  local base = vim.fs.basename(dir)
  local ok, err = handle:start(dir, {}, function(event_err, filename, events)
    -- A fast event: only mark the directory, the flush does the rest. An event about the
    -- directory itself (inotify reports its removal as a rename of its own name) means
    -- the watch may be dead even if a new directory gets the same inode: watch again.
    if event_err or (events and events.rename and (filename == nil or filename == "" or filename == base)) then
      watcher.broken = true
    end
    state.pending[dir] = true
    debounce()
  end)
  if not ok then
    close_handle(handle)
    state.failed[dir] = true
    log.warn("watch: cannot watch %s: %s", dir, err)
    return
  end
  state.dirs[dir] = watcher
  log.trace("watch: watching %s", dir)
end

local poll_missing

---Poll the missing directories while there are any.
local function update_poll()
  if next(state.missing) == nil then
    if state.poll then
      state.poll:stop()
      state.poll:close()
      state.poll = nil
    end
    return
  end
  if state.poll then
    return
  end
  local timer, err = vim.uv.new_timer()
  if not timer then
    require("duet.log").warn("watch: cannot poll for missing directories: %s", err)
    return
  end
  state.poll = timer
  timer:start(POLL_MS, POLL_MS, function()
    vim.schedule(poll_missing)
  end)
end

---Watch the directories of the listed file buffers, and only those. A watcher whose
---directory is gone, was replaced (removed and created again) or reported an event about
---itself is closed, and the directory is watched again if it exists. Directories that do
---not exist are polled until they do.
function M.sync()
  state.sync_scheduled = false
  if not state.active then
    return
  end
  local want = {}
  local existed = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local dir = buffer_dir(buf)
    if dir then
      if want[dir] == nil then
        want[dir] = dir_stat(dir) or false
      end
      -- Kept from when the buffer was first seen, so a file created since still counts
      -- as new when its buffer is checked.
      if state.existed[buf] == nil then
        existed[buf] = file_exists(buf)
      else
        existed[buf] = state.existed[buf]
      end
    end
  end
  state.existed = existed
  for dir, watcher in pairs(state.dirs) do
    local stat = want[dir]
    if not stat or watcher.broken or stat.ino ~= watcher.ino or stat.dev ~= watcher.dev then
      unwatch(dir)
    end
  end
  state.missing = {}
  for dir, stat in pairs(want) do
    if not stat then
      state.missing[dir] = true
    elseif not state.dirs[dir] and not state.failed[dir] then
      watch(dir, stat)
    end
  end
  update_poll()
end

---Check the missing directories that exist now: watch them and check their buffers.
poll_missing = function()
  if not state.active then
    return
  end
  local found = false
  for dir in pairs(state.missing) do
    if dir_stat(dir) then
      state.pending[dir] = true
      found = true
    end
  end
  if found then
    M.flush()
  end
end

---Sync once the current event is done: BufDelete and BufWipeout fire while the buffer
---is still listed. Several calls in a row sync once.
local function schedule_sync()
  if state.sync_scheduled then
    return
  end
  state.sync_scheduled = true
  vim.schedule(M.sync)
end

---Run :checktime for the watched buffers in `dirs`. While the user is typing, buffers
---that would prompt stay pending until the mode changes. Buffers that can't be checked
---now (textlock) stay pending and are retried after another debounce; other errors are
---reported and dropped.
---@param dirs table<string, true>
local function check(dirs)
  local typing = M.typing(vim.api.nvim_get_mode().mode)
  local again = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local dir = buffer_dir(buf)
    if dir and dirs[dir] and vim.api.nvim_buf_is_loaded(buf) then
      if typing and would_prompt(buf) then
        state.pending[dir] = true
      else
        local ok, err = pcall(vim.cmd.checktime, buf)
        if vim.api.nvim_buf_is_valid(buf) then
          state.existed[buf] = file_exists(buf)
        end
        if not ok then
          err = tostring(err)
          if is_transient(err) then
            require("duet.log").debug("watch: checktime %d failed, retrying: %s", buf, err)
            state.pending[dir] = true
            again = true
          else
            local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
            require("duet.util").notify(("watch: cannot check %s: %s"):format(name, err), vim.log.levels.WARN)
          end
        end
      end
    end
  end
  if again then
    retry()
  end
end

---Check the pending directories, unless the editor is busy: then wait again. Watchers are
---synced first, so a directory that was replaced is watched again.
function M.flush()
  if not state.active or next(state.pending) == nil then
    return
  end
  if M.busy(vim.api.nvim_get_mode(), vim.fn.getcmdwintype() ~= "") then
    retry()
    return
  end
  local dirs = state.pending
  state.pending = {}
  state.deadline = nil
  M.sync()
  check(dirs)
end

---Check every watched buffer now, as on leaving the agent's terminal or gaining focus.
---Waits like a change on disk does while the editor is busy or the user is typing.
function M.checktime()
  if not state.active then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local dir = buffer_dir(buf)
    if dir then
      state.pending[dir] = true
    end
  end
  M.flush()
end

local function set_autocmds()
  local group = vim.api.nvim_create_augroup("duet.watch", { clear = true })
  state.augroup = group
  vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout", "BufFilePost", "BufWritePost" }, {
    group = group,
    desc = "duet: watch the directories of file buffers",
    callback = schedule_sync,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "duet: remember that the file exists",
    callback = function(ev)
      if state.existed[ev.buf] ~= nil then
        state.existed[ev.buf] = true
      end
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "buflisted", "buftype" },
    desc = "duet: watch the directories of file buffers",
    callback = schedule_sync,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "autoread",
    desc = "duet: keep the 'autoread' the user sets",
    callback = function()
      if vim.v.option_type ~= "local" then
        state.saved_autoread = nil
      end
    end,
  })
  -- Checks that waited for the user to stop typing, or for the command line to close.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    desc = "duet: check files that waited for a mode change",
    callback = function()
      if next(state.pending) ~= nil then
        vim.schedule(M.flush)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermLeave", {
    group = group,
    desc = "duet: check for files the agent changed",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "duet_terminal" then
        vim.schedule(M.checktime)
      end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "duet: check for files the agent changed",
    callback = function()
      vim.schedule(M.checktime)
    end,
  })
end

local function start()
  local timer, err = vim.uv.new_timer()
  if not timer then
    require("duet.log").warn("watch: cannot start watching: %s", err)
    return
  end
  state.active = true
  state.timer = timer
  -- Before the autocmds: the OptionSet for 'autoread' is for the user's changes only.
  if config().autoread and not vim.go.autoread then
    state.saved_autoread = vim.go.autoread
    vim.go.autoread = true
  end
  set_autocmds()
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
  for dir in pairs(state.dirs) do
    unwatch(dir)
  end
  state.failed = {}
  state.missing = {}
  state.existed = {}
  state.pending = {}
  state.deadline = nil
  update_poll()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  -- After the autocmds are gone, so this is not taken for the user's change. A value the
  -- user set while watching is kept (the OptionSet autocmd forgot the saved one).
  if state.saved_autoread ~= nil then
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
---@return { active: boolean, dirs: string[], failed: string[], missing: string[], poll: boolean, pending: string[], augroup: integer|nil, timer: boolean, saved_autoread: boolean|nil }
function M._state()
  local function keys(t)
    local list = vim.tbl_keys(t)
    table.sort(list)
    return list
  end
  return {
    active = state.active,
    dirs = keys(state.dirs),
    failed = keys(state.failed),
    missing = keys(state.missing),
    poll = state.poll ~= nil,
    pending = keys(state.pending),
    augroup = state.augroup,
    timer = state.timer ~= nil,
    saved_autoread = state.saved_autoread,
  }
end

return M
