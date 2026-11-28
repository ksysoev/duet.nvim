---@brief Agent terminal sessions: spawn the agent CLI in a Neovim terminal, show and hide it.
--- There is one session per (agent, project root). The project root is the git root of the
--- current directory, or the directory itself outside a repository. Each session has a run
--- dir, `stdpath("run")/duet/<id>/`, that holds the files the adapter asked for. The run dir
--- is removed when the job exits. See |duet-terminal|.

local M = {}

---@class duet.Session
---@field id string session id, also the name of its run dir
---@field agent duet.Agent adapter instance the session was started with
---@field root string project root, the agent's working directory
---@field run_dir string absolute path of the per-session directory
---@field buf integer terminal buffer
---@field job integer|nil job id while the agent runs
---@field exit_code integer|nil exit code once the job has exited
---@field exit_seen boolean the terminal has been shown since the job exited
---@field last_used integer order of last use, higher is more recent
---@field stopping boolean the job is being stopped by duet, so its exit is expected
---@field stopped boolean duet stopped the agent while it ran (stop, restart, wiping the buffer)
---@field seen_ready boolean the agent's TUI has been ready for input at least once
---@field rows integer|nil height of the tallest window last seen showing the terminal
local Session = {}
Session.__index = Session
M.Session = Session

---@type table<string, duet.Session>
local sessions = {}
local id_counter = 0
local use_counter = 0
---@type integer|nil
local augroup
-- Set on WinEnter when Neovim is about to enlarge the window entered to 'winwidth' or
-- 'winheight', and cleared by the WinResized that follows: that resize is not the user's.
local enlarging = false

local FILETYPE = "duet_terminal"
-- Readiness polling (Session:when_ready): how often, and how many lines the adapter's
-- is_ready and read_input see at least. They see the terminal's screen down to its last
-- non-blank row, or the last READY_LINES lines ending there if those reach higher (also for a
-- terminal no window has shown yet). The live input box is on the screen, however tall typed
-- input makes it; reading no higher keeps old boxes in the scrollback, which could pass for
-- ready while a dialog is open, out of view.
local READY_POLL_MS = 50
local READY_LINES = 50

local function config()
  return require("duet.config").get().terminal
end

local function next_use()
  use_counter = use_counter + 1
  return use_counter
end

local function new_id()
  id_counter = id_counter + 1
  return ("%d-%d-%d"):format(vim.uv.os_getpid(), os.time(), id_counter)
end

---Directory that holds every session's run dir.
---@return string
function M.run_root()
  return vim.fs.joinpath(vim.fn.stdpath("run") --[[@as string]], "duet")
end

---The parent's RPC address, starting a server if Neovim has none (e.g. `--headless`).
---@return string
function M.servername()
  if vim.v.servername == "" then
    vim.fn.serverstart()
  end
  return vim.v.servername
end

---Project root for a directory: its git root, or the directory itself.
---@param cwd? string default: the current window's working directory
---@return string
function M.root(cwd)
  cwd = cwd or vim.fn.getcwd()
  return require("duet.util").git_root(cwd) or vim.fs.normalize(vim.fs.abspath(cwd))
end

---Whether `path` is strictly inside `dir`.
---@param path string
---@param dir string
---@return boolean
local function is_inside(path, dir)
  local rel, inside = require("duet.util").relpath(path, dir)
  return inside and rel ~= "."
end

---Write the plan's files with mode 0600 into a new run dir (mode 0700).
---@param run_dir string
---@param files duet.LaunchFile[]
---@return boolean|nil ok
---@return string|nil err
local function write_files(run_dir, files)
  for _, file in ipairs(files) do
    if type(file) ~= "table" or type(file.path) ~= "string" or type(file.content) ~= "string" then
      return nil, "terminal: launch plan has a malformed file entry"
    end
    if not is_inside(file.path, run_dir) then
      return nil, ("terminal: launch file '%s' is outside the run dir %s"):format(file.path, run_dir)
    end
  end
  if vim.fn.mkdir(run_dir, "p", 448) == 0 then
    return nil, ("terminal: cannot create run dir %s"):format(run_dir)
  end
  for _, file in ipairs(files) do
    vim.fn.mkdir(vim.fs.dirname(file.path), "p", 448)
    local fd, err = vim.uv.fs_open(file.path, "w", 384)
    if not fd then
      return nil, ("terminal: cannot write %s: %s"):format(file.path, err)
    end
    local _, write_err = vim.uv.fs_write(fd, file.content)
    vim.uv.fs_close(fd)
    if write_err then
      return nil, ("terminal: cannot write %s: %s"):format(file.path, write_err)
    end
  end
  return true
end

---Remove a run dir, but only one under run_root().
---@param run_dir string
local function remove_run_dir(run_dir)
  if is_inside(run_dir, M.run_root()) then
    vim.fn.delete(run_dir, "rf")
  end
end

---@param plan any
---@return string|nil err
local function check_plan(plan)
  if type(plan) ~= "table" then
    return "terminal: adapter returned no launch plan"
  end
  if type(plan.argv) ~= "table" or #plan.argv == 0 then
    return "terminal: launch plan has an empty argv"
  end
  for _, word in ipairs(plan.argv) do
    if type(word) ~= "string" then
      return "terminal: launch plan argv must be strings"
    end
  end
  if plan.env ~= nil and type(plan.env) ~= "table" then
    return "terminal: launch plan env must be a table"
  end
  if plan.files ~= nil and type(plan.files) ~= "table" then
    return "terminal: launch plan files must be a list"
  end
  return nil
end

-- Layout --------------------------------------------------------------------

---Resolve a size option: a number <= 1 is a fraction of `total`, larger numbers are
---absolute. The result is clamped to [1, total].
---@param value number
---@param total integer
---@return integer
function M.resolve_size(value, total)
  local size = value <= 1 and math.floor(value * total) or math.floor(value)
  return math.max(1, math.min(size, total))
end

---Largest size an absolute split may take so the other windows keep `keep` cells, plus
---one for the separator or status line between them and the split. When `total` is too
---small for both, the split and the rest share it evenly. Pure.
---@param total integer editor columns, or lines available for windows
---@param keep? integer `split.min_code_width` or `split.min_code_height` (default 0)
---@return integer
function M.split_cap(total, keep)
  keep = keep or 0
  return math.max(1, total - keep - 1, math.floor((total - 1) / 2))
end

---Size a split should have. A fraction (`value <= 1`) is its share of `total` and is not
---capped. An absolute size is the user's own size `hand` when they resized the split by
---hand, otherwise `value`, capped by `split_cap()`. Pure.
---@param value number `split.width` or `split.height`
---@param total integer editor columns, or lines available for windows
---@param keep? integer `split.min_code_width` or `split.min_code_height` (default 0)
---@param hand? integer the size the user gave the split by hand
---@return integer
function M.split_target(value, total, keep, hand)
  if value <= 1 then
    return M.resolve_size(value, total)
  end
  return math.max(1, math.min(hand or math.floor(value), M.split_cap(total, keep)))
end

---Cells a border takes on each side. Pure. A list repeats to 8 parts (corners and edges,
---clockwise from the top-left), as in |nvim_open_win()|; an empty edge takes no space.
---@param border? string|(string|string[])[]
---@return integer top
---@return integer right
---@return integer bottom
---@return integer left
function M.border_size(border)
  if border == nil or border == "" or border == "none" then
    return 0, 0, 0, 0
  elseif border == "shadow" then
    return 0, 1, 1, 0
  elseif type(border) == "string" then
    return 1, 1, 1, 1
  end
  local function edge(i)
    local part = border[(i - 1) % #border + 1]
    if type(part) == "table" then
      part = part[1]
    end
    return (part ~= nil and part ~= "") and 1 or 0
  end
  return edge(2), edge(4), edge(6), edge(8)
end

---@class duet.EditorSize
---@field columns integer editor width
---@field lines integer rows available for windows
---@field top? integer rows taken above them (the tabline)

---Window config for a layout. Pure: depends only on its arguments.
---@param layout "float"|"right"|"left"|"bottom"
---@param opts table the `terminal` config
---@param editor duet.EditorSize
---@param title? string float title, shown when the border has a top edge
---@return vim.api.keyset.win_config
function M.win_config(layout, opts, editor, title)
  local columns, lines = editor.columns, editor.lines
  if layout == "float" then
    local border = opts.float.border
    local top, right, bottom, left = M.border_size(border)
    local pad_w, pad_h = left + right, top + bottom
    local width = M.resolve_size(opts.float.width, math.max(1, columns - pad_w))
    local height = M.resolve_size(opts.float.height, math.max(1, lines - pad_h))
    local cfg = {
      relative = "editor",
      style = "minimal",
      border = border,
      width = width,
      height = height,
      row = (editor.top or 0) + math.max(0, math.floor((lines - height - pad_h) / 2)),
      col = math.max(0, math.floor((columns - width - pad_w) / 2)),
    }
    if title and top > 0 then
      cfg.title = title
      cfg.title_pos = "center"
    end
    return cfg
  elseif layout == "bottom" then
    return { split = "below", win = -1, height = M.split_target(opts.split.height, lines, opts.split.min_code_height) }
  end
  return { split = layout, win = -1, width = M.split_target(opts.split.width, columns, opts.split.min_code_width) }
end

---Size of the window a layout opens, for a terminal started without one: the float's size,
---a side split's width by the rows windows have, or a bottom split's height by the editor's
---width. Pure.
---@param layout "float"|"right"|"left"|"bottom"
---@param opts table the `terminal` config
---@param editor duet.EditorSize
---@return integer width
---@return integer height
function M.layout_size(layout, opts, editor)
  local cfg = M.win_config(layout, opts, editor)
  if layout == "float" then
    return cfg.width, cfg.height
  elseif layout == "bottom" then
    return editor.columns, cfg.height
  end
  return cfg.width, editor.lines
end

---The editor area windows can use: the tabline, the command line and a status line are
---left out.
---@return duet.EditorSize
local function editor_size()
  local tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local top = tabline and 1 or 0
  local status = vim.o.laststatus == 0 and 0 or 1
  return { columns = vim.o.columns, lines = math.max(1, vim.o.lines - vim.o.cmdheight - status - top), top = top }
end

---The room windows have, as a string to compare: it changes with the editor size, the
---tabline, 'cmdheight' and 'laststatus'.
---@param editor duet.EditorSize
---@return string
local function room_key(editor)
  return ("%d:%d:%d"):format(editor.columns, editor.lines, editor.top or 0)
end

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

---Set the terminal's window options. They are local to the window's current buffer
---(`vim.wo[win][0]`, like :setlocal), so call this again after putting a new buffer in
---the window. `w:duet_layout` records the layout for resizing. Without a layout, e.g. a
---window of the user's that shows the terminal, only the display options are set, so
---duet does not size the window or fix its width.
---@param win integer
---@param layout? "float"|"right"|"left"|"bottom"
local function apply_window_options(win, layout)
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.wrap = false
  wo.list = false
  wo.cursorline = false
  wo.colorcolumn = ""
  wo.statuscolumn = ""
  -- Only a split fixes its size. Any other window keeps its own values, e.g. a sidebar of
  -- the user's that shows the terminal.
  if layout == "bottom" then
    wo.winfixheight = true
  elseif layout == "right" or layout == "left" then
    wo.winfixwidth = true
  end
  vim.w[win].duet_layout = layout
end

---The size a split's layout sets: "height" for `"bottom"`, "width" for `"right"` and
---`"left"`, nil for a float or a window that is not a duet terminal.
---@param win integer
---@return "width"|"height"|nil
local function split_axis(win)
  local layout = vim.w[win].duet_layout
  if layout == "bottom" then
    return "height"
  elseif layout == "right" or layout == "left" then
    return "width"
  end
end

---@param win integer
---@param axis "width"|"height"
---@return integer
local function get_size(win, axis)
  return axis == "height" and vim.api.nvim_win_get_height(win) or vim.api.nvim_win_get_width(win)
end

---Record what duet sized a window for. For a split, `w:duet_size` is the size duet
---accounts for: a later change to any other size, while the room stays the same, is the
---user's (see `on_win_resized()`). For a split or a float, `w:duet_room` is the room it
---was sized for (see `room_key()`). A window without a layout, e.g. one of the user's that
---shows the terminal, is not recorded.
---@param win integer
---@param editor? duet.EditorSize default: editor_size()
local function record_size(win, editor)
  local axis = split_axis(win)
  if axis then
    vim.w[win].duet_size = get_size(win, axis)
  end
  if vim.w[win].duet_layout then
    vim.w[win].duet_room = room_key(editor or editor_size())
  end
end

---Open a window for `buf` with the configured layout. Focus does not move.
---@param buf integer
---@param title string
---@return integer|nil win
---@return string|nil err e.g. an invalid border, or E11 in the command-line window
local function open_window(buf, title)
  local opts = config()
  local cfg = M.win_config(opts.layout, opts, editor_size(), title)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, cfg)
  if not ok then
    return nil, ("terminal: cannot open window: %s"):format(win)
  end
  apply_window_options(win, opts.layout)
  record_size(win)
  return win
end

---@param agent duet.Agent
---@return string
local function title(agent)
  return (" %s "):format(agent.name)
end

---Centre and size a float again for the editor size.
---@param win integer
---@param opts table the `terminal` config
---@param editor duet.EditorSize
local function fit_float(win, opts, editor)
  -- Use the border the window has, which a later setup() may have changed in config.
  -- Neovim 0.11 leaves `border` out of the config of a window without one.
  local border = vim.api.nvim_win_get_config(win).border or "none"
  local float = vim.tbl_extend("force", opts.float, { border = border })
  local cfg = M.win_config("float", vim.tbl_extend("force", opts, { float = float }), editor)
  cfg.title, cfg.title_pos, cfg.border = nil, nil, nil
  vim.api.nvim_win_set_config(win, cfg)
  record_size(win, editor)
end

---Give a split the size `split_target()` says for the editor size: a fraction gets its
---share, an absolute size is capped to leave room for the code and grows back up to the
---configured size, or to the user's own size once they resized the split by hand. The
---size it ends up with is recorded as duet's, so `on_win_resized()` does not take it for
---the user's. Does nothing for a float or a window that is not a duet split.
---@param win integer
---@param opts table the `terminal` config
---@param editor duet.EditorSize
local function fit_split(win, opts, editor)
  local axis = split_axis(win)
  if not axis or is_float(win) then
    return
  end
  local value = opts.split[axis]
  -- A hand size counts only under the size option it was made with: after setup()
  -- changes that option, the split takes the new size.
  local hand = vim.w[win].duet_hand_for == value and vim.w[win].duet_hand or nil
  local size
  if axis == "height" then
    size = M.split_target(value, editor.lines, opts.split.min_code_height, hand)
  else
    size = M.split_target(value, editor.columns, opts.split.min_code_width, hand)
  end
  if size ~= get_size(win, axis) then
    if axis == "height" then
      vim.api.nvim_win_set_height(win, size)
    else
      vim.api.nvim_win_set_width(win, size)
    end
  end
  record_size(win, editor)
end

---The windows that show a duet terminal with a layout duet gave them, optionally only
---those in one tab.
---@param tab? integer
---@return integer[]
local function terminal_windows(tab)
  local wins = {}
  for _, session in pairs(sessions) do
    for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
      if vim.w[win].duet_layout and (not tab or vim.api.nvim_win_get_tabpage(win) == tab) then
        wins[#wins + 1] = win
      end
    end
  end
  return wins
end

---@class duet.RelayoutOpts
---@field tab? integer only the windows in this tab (default: every tab)
---@field stale_only? boolean only the windows sized for a room other than the current one

---Size duet terminal windows again for the room windows have: floats with fit_float(),
---splits with fit_split(). Whatever Neovim did to a split's size meanwhile is recorded as
---duet's. VimResized sizes every window, in every tab. A change in the room without an
---editor resize, e.g. from the tabline, 'cmdheight' or 'laststatus', is caught on
---WinResized and sizes only the current tab's windows: another tab may have its own
---'cmdheight', and Neovim resizes its windows when it is entered, which then comes here.
---@param opts? duet.RelayoutOpts
local function relayout(opts)
  opts = opts or {}
  local cfg = config()
  local editor = editor_size()
  local room = room_key(editor)
  for _, win in ipairs(terminal_windows(opts.tab)) do
    if not (opts.stale_only and vim.w[win].duet_room == room) then
      if is_float(win) then
        fit_float(win, cfg, editor)
      else
        fit_split(win, cfg, editor)
      end
    end
  end
end

---Whether a duet terminal window in the current tab was sized for a room other than the
---current one.
---@return boolean
local function room_changed()
  local room = room_key(editor_size())
  for _, win in ipairs(terminal_windows(vim.api.nvim_get_current_tabpage())) do
    if vim.w[win].duet_room ~= room then
      return true
    end
  end
  return false
end

---On WinResized: a split whose size changed since duet last recorded it was resized by
---the user (or by something else that left the room for windows as it was), so that size
---becomes the one the split keeps and grows back to, in `w:duet_hand`. `w:duet_hand_for`
---records the size option it was made under. Only windows that show a duet terminal count:
---a panel the user put another buffer in (e.g. with :edit) is not tracked. Resizes that are
---Neovim's are not the user's: those that come with entering a window ('winwidth',
---'winheight') are recorded as duet's, and those that come with a change in the room
---(the tabline, 'cmdheight', 'laststatus', entering a tab) make duet size the current tab's
---windows again.
local function on_win_resized()
  if room_changed() then
    relayout({ tab = vim.api.nvim_get_current_tabpage(), stale_only = true })
    enlarging = false
    return
  end
  for _, win in ipairs(vim.v.event.windows or {}) do
    local axis = vim.api.nvim_win_is_valid(win) and split_axis(win)
    if axis and not is_float(win) and vim.b[vim.api.nvim_win_get_buf(win)].duet_session then
      local size = get_size(win, axis)
      if enlarging then
        record_size(win)
      elseif size ~= vim.w[win].duet_size then
        vim.w[win].duet_hand = size
        vim.w[win].duet_hand_for = config().split[axis]
        vim.w[win].duet_size = size
      end
    end
  end
  enlarging = false
end

---On WinEnter, before Neovim sizes the window entered: whether it will enlarge it, which
---it does for a window narrower than 'winwidth' or lower than 'winheight' whose size is
---not fixed.
local function on_win_enter()
  local win = vim.api.nvim_get_current_win()
  if is_float(win) then
    return
  end
  local wo = vim.wo[win]
  enlarging = (vim.api.nvim_win_get_width(win) < vim.o.winwidth and not wo.winfixwidth)
    or (vim.api.nvim_win_get_height(win) < vim.o.winheight and not wo.winfixheight)
end

-- Sessions ------------------------------------------------------------------

local function ensure_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("duet.terminal", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    desc = "duet: stop agent sessions",
    callback = function()
      M.stop_all()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    desc = "duet: resize agent terminals",
    callback = function()
      relayout()
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = augroup,
    desc = "duet: remember agent terminals resized by hand, follow changes in the room",
    callback = on_win_resized,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    desc = "duet: tell window enlargement from resizes by hand",
    callback = on_win_enter,
  })
end

---Mark the job as stopped by duet and clean up now. Safe to call more than once.
---@param self duet.Session
local function release(self)
  self.stopping = true
  sessions[self.id] = nil
  if self.job then
    self.stopped = true
    pcall(vim.fn.jobstop, self.job)
  end
  remove_run_dir(self.run_dir)
  require("duet.watch").refresh()
end

---Whether `win` is the only non-floating window of its tab (it can't be closed then).
---@param win integer
---@return boolean
local function is_last_window(win)
  if is_float(win) then
    return false
  end
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if other ~= win and not is_float(other) then
      return false
    end
  end
  return true
end

---A listed, unnamed, unmodified and empty buffer other than `except`, or a new one. Reusing
---one keeps empty buffers from piling up when the terminal leaves a tab's last window.
---@param except integer
---@return integer
local function empty_buffer(except)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      b ~= except
      and vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
      and not vim.bo[b].modified
      and vim.api.nvim_buf_get_name(b) == ""
      and vim.api.nvim_buf_line_count(b) == 1
      and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == ""
    then
      return b
    end
  end
  return vim.api.nvim_create_buf(true, false)
end

---Drop the split state duet keeps on a window (see `record_size()` and `on_win_resized()`),
---once its terminal has left it, so the window is not sized as a split later.
---@param win integer
local function forget_window(win)
  vim.w[win].duet_layout = nil
  vim.w[win].duet_size = nil
  vim.w[win].duet_room = nil
  vim.w[win].duet_hand = nil
  vim.w[win].duet_hand_for = nil
end

---Take `buf` out of `win`: close the window, or, when it is the last window of its tab
---and can't be closed, show the alternate buffer (or a new empty one) in it.
---@param win integer
---@param buf integer
---@return boolean ok
---@return any err
local function close_window(win, buf)
  if not is_last_window(win) then
    return pcall(vim.api.nvim_win_close, win, false)
  end
  local alt = vim.api.nvim_win_call(win, function()
    return vim.fn.bufnr("#")
  end)
  if alt <= 0 or alt == buf or not vim.bo[alt].buflisted then
    alt = empty_buffer(buf)
  end
  -- A buffer put in a window takes over the local values of the one it replaces, unless it
  -- was shown there before. Turn a split's fixed size off first, so neither the buffer put
  -- here nor the terminal, if it comes back to this window, keeps it.
  local axis = split_axis(win)
  if axis then
    vim.wo[win][0].winfixwidth = false
    vim.wo[win][0].winfixheight = false
  end
  local ok, err = pcall(vim.api.nvim_win_set_buf, win, alt)
  if ok then
    forget_window(win)
  elseif axis then
    vim.wo[win][0].winfixwidth = axis == "width"
    vim.wo[win][0].winfixheight = axis == "height"
  end
  return ok, err
end

---Close every window that shows the session's buffer (see close_window). Wiping a buffer
---only closes the current window if autocommands let it (e.g. a snacks.nvim dashboard next
---to it does not), and leaves an empty buffer in it otherwise, so close them first.
---@param self duet.Session
local function close_windows(self)
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    local ok, err = close_window(win, self.buf)
    if not ok then
      require("duet.log").warn("session %s: cannot close window %d: %s", self.id, win, err)
    end
  end
end

-- Exit handling -------------------------------------------------------------

local SIGNALS = {
  [1] = "hangup (SIGHUP)",
  [2] = "interrupted (SIGINT)",
  [3] = "quit (SIGQUIT)",
  [6] = "aborted (SIGABRT)",
  [9] = "killed (SIGKILL)",
  [13] = "broken pipe (SIGPIPE)",
  [15] = "terminated (SIGTERM)",
}

---Lines of output shown with an error exit.
local TAIL_LINES = 5
---Longest line shown; TUI lines are as wide as the terminal.
local TAIL_WIDTH = 200

---Highest signal number (Linux real-time signals go up to 64; macOS stops at 31).
local MAX_SIGNAL = 64

---Why a job exited with `code`, in words. Pure. Neovim reports a job killed by signal N
---as 128 + N; larger codes (e.g. 255) are plain exit codes.
---@param code integer non-zero exit code
---@return string
function M.exit_reason(code)
  if code > 128 and code <= 128 + MAX_SIGNAL then
    return SIGNALS[code - 128] or ("signal %d"):format(code - 128)
  elseif code == 127 then
    return "command not found"
  elseif code == 126 then
    return "command not executable"
  end
  return "see the terminal output"
end

---The last `n` non-blank lines of terminal output, trailing whitespace trimmed. Pure.
---Neovim's "[Process exited N]" line is left out, and long lines are cut.
---@param lines string[]
---@param n integer
---@return string[]
function M.tail(lines, n)
  local result = {}
  for i = #lines, 1, -1 do
    if #result == n then
      break
    end
    local line = lines[i]:gsub("%s+$", "")
    if line ~= "" and not line:match("^%[Process exited %-?%d+%]$") then
      if vim.fn.strchars(line) > TAIL_WIDTH then
        line = vim.fn.strcharpart(line, 0, TAIL_WIDTH - 1) .. "…"
      end
      table.insert(result, 1, line)
    end
  end
  return result
end

---The error shown when an agent exits with a non-zero code. Pure.
---@param name string agent name
---@param code integer
---@param lines string[] the terminal's last lines of output (see M.tail)
---@param hint? string what the user can do next, as the last line
---@return string
function M.exit_message(name, code, lines, hint)
  local parts = { ("%s exited with code %d: %s"):format(name, code, M.exit_reason(code)) }
  vim.list_extend(parts, lines)
  parts[#parts + 1] = hint
  return table.concat(parts, "\n")
end

---@class duet.ExitKeys
---@field restart? string key that restarts the agent, if duet mapped one
---@field close? string key that closes the terminal, if duet mapped one

---What the user can do with a kept exited terminal, for the end of the exit message. Pure.
---@param keys duet.ExitKeys the keys duet mapped in the terminal
---@param hidden boolean the terminal is not shown in the current tab
---@return string|nil
function M.exit_hint(keys, hidden)
  local actions = {}
  if keys.restart then
    actions[#actions + 1] = ("%s to restart the agent"):format(keys.restart)
  end
  if keys.close then
    actions[#actions + 1] = ("%s to close it"):format(keys.close)
  end
  local press = #actions > 0 and ("press " .. table.concat(actions, " or ")) or nil
  if hidden then
    return press and ("Run :Duet open to see the output, then %s."):format(press) or "Run :Duet open to see the output."
  end
  return press and ("In the terminal, %s."):format(press) or nil
end

---Whether `close_on_exit` closes the terminal after an exit with `code`.
---@param code integer
---@return boolean
local function closes_on(code)
  local policy = config().close_on_exit
  return policy == "always" or (policy == "success" and code == 0)
end

---Restart an exited session from its terminal, in the same window.
---@param self duet.Session
local function restart_exited(self)
  if sessions[self.id] ~= self or self.job then
    return
  end
  local new, err = self:restart()
  if not new then
    require("duet.util").notify(err, vim.log.levels.ERROR)
    return
  end
  if new:is_visible() then
    new:focus()
  end
end

---Keys the user maps in Normal mode with `terminal.keys`, normalized with vim.keycode().
---`"normal_mode"` maps Terminal-mode only, so it does not count.
---@return table<string, true>
local function user_keys()
  local keys = {}
  for lhs, action in pairs(config().keys) do
    if action and action ~= "normal_mode" then
      keys[vim.keycode(lhs)] = true
    end
  end
  return keys
end

---Keep an exited terminal useful: `i`, `a`, `I` and `A` restart the agent in the same
---window, and `q` closes the terminal and ends the session; keys the user maps in
---`terminal.keys` keep their action. Terminal-mode entered any other way (from Insert mode
---in another window, a mouse click, a plugin) is left again at once: Neovim would delete
---the terminal on the next key and leave an empty buffer in the window. Entering the
---terminal's window counts as seeing it (see M.open).
---@param self duet.Session
---@return duet.ExitKeys keys the keys duet mapped
local function keep_exited(self)
  local taken = user_keys()
  local keys = {}
  local function map(lhs, fn, desc)
    if taken[vim.keycode(lhs)] then
      return false
    end
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, desc = desc })
    return true
  end
  for _, lhs in ipairs({ "i", "a", "I", "A" }) do
    if map(lhs, function()
      restart_exited(self)
    end, "duet: restart the exited agent") then
      keys.restart = keys.restart or lhs
    end
  end
  if map("q", function()
    self:stop()
  end, "duet: close the exited agent terminal") then
    keys.close = "q"
  end
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = augroup,
    buffer = self.buf,
    desc = "duet: the exited agent terminal has been seen",
    callback = function()
      self.exit_seen = true
    end,
  })
  vim.api.nvim_create_autocmd("TermEnter", {
    group = augroup,
    buffer = self.buf,
    desc = "duet: keep the exited agent terminal",
    callback = function()
      vim.cmd.stopinsert()
    end,
  })
  return keys
end

---Close an exited session's terminal: its windows, then its buffer. BufUnload releases
---the session.
---@param self duet.Session
---@return boolean ok false if the buffer could not be wiped (e.g. E11)
local function close_exited(self)
  close_windows(self)
  local ok, err = pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  if not ok then
    require("duet.log").warn("session %s: cannot close the terminal: %s", self.id, err)
  end
  return ok
end

---Keep an exited session's terminal, with its output.
---@param self duet.Session
---@return duet.ExitKeys keys the keys duet mapped in it
local function keep_terminal(self)
  -- Only the current tab counts: a terminal left open in another tab has not been seen.
  self.exit_seen = self:is_visible()
  local keys = keep_exited(self)
  -- In terminal mode, the next key would close the exited terminal and its output.
  if vim.api.nvim_get_current_buf() == self.buf and vim.api.nvim_get_mode().mode == "t" then
    vim.cmd.stopinsert()
  end
  return keys
end

---@param self duet.Session
---@param code integer
local function on_exit(self, code)
  self.job = nil
  self.exit_code = code
  remove_run_dir(self.run_dir)
  require("duet.watch").refresh()
  if self.stopping then
    return
  end
  require("duet.log").debug("session %s (%s) exited with code %d", self.id, self.agent.name, code)
  local valid = vim.api.nvim_buf_is_valid(self.buf)
  local close = closes_on(code)
  -- Read the output now: closing wipes it.
  local lines = (code ~= 0 and valid) and M.tail(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), TAIL_LINES) or {}

  ---Report a non-zero exit, with a hint when the terminal was kept.
  ---@param keys? duet.ExitKeys the keys mapped in the kept terminal, nil if it was closed
  local function report(keys)
    if code == 0 then
      return
    end
    local hint = keys and M.exit_hint(keys, not self.exit_seen) or nil
    require("duet.util").notify(M.exit_message(self.agent.name, code, lines, hint), vim.log.levels.ERROR)
  end

  -- Close or keep the terminal, then report what happened.
  local function finish()
    if close and close_exited(self) then
      report(nil)
      return
    end
    report(keep_terminal(self))
  end

  if not valid then
    report(nil)
  elseif close and vim.fn.getcmdwintype() ~= "" then
    -- Windows can't be closed from the command-line window (E11): close once it is left.
    vim.api.nvim_create_autocmd("CmdwinLeave", {
      group = augroup,
      once = true,
      desc = "duet: close the exited agent terminal",
      callback = function()
        vim.schedule(function()
          if not self.stopping and vim.api.nvim_buf_is_valid(self.buf) then
            finish()
          end
        end)
      end,
    })
  else
    finish()
  end
end

-- Key actions on links (see duet.links), with their descriptions and modes (default:
-- Normal mode). `variants` gives more keys mapped to the action along with `lhs`, unless
-- `terminal.keys` names them itself.
---@type table<string, { desc: string, fn: fun(lhs: string), modes?: string[], variants?: fun(lhs: string): string[] }>
local LINK_ACTIONS = {
  open_link = {
    desc = "duet: open the file link under the cursor",
    fn = function(lhs)
      -- <CR> still moves down where there is nothing to open. Other keys say so: their
      -- built-in action fails in a terminal (gf) or would surprise.
      local enter = vim.keycode(lhs) == vim.keycode("<CR>")
      require("duet.links").follow({ fallback = enter and lhs or nil })
    end,
  },
  open_link_mouse = {
    desc = "duet: open the file link clicked",
    -- A Terminal-mode mapping gets the click before the agent, even one that tracks the
    -- mouse, so links open without leaving Terminal mode first.
    modes = { "t", "n" },
    fn = function(lhs)
      require("duet.links").click(lhs)
    end,
    -- A CTRL-click right after a plain click at the same place is `<2-C-LeftMouse>`.
    variants = function(lhs)
      return require("duet.links").counted_clicks(lhs)
    end,
  },
  next_link = {
    desc = "duet: next file link",
    fn = function()
      require("duet.links").jump(1)
    end,
  },
  prev_link = {
    desc = "duet: previous file link",
    fn = function()
      require("duet.links").jump(-1)
    end,
  },
}

---@param self duet.Session
local function set_keymaps(self)
  local keys = config().keys
  local named = {} -- keys in terminal.keys, even turned off: variants don't replace them
  for lhs in pairs(keys) do
    named[vim.keycode(lhs)] = true
  end
  for lhs, action in pairs(keys) do
    if action == "normal_mode" then
      vim.keymap.set("t", lhs, [[<C-\><C-n>]], { buffer = self.buf, desc = "duet: leave terminal mode" })
    elseif action == "hide" then
      vim.keymap.set({ "t", "n" }, lhs, function()
        self:hide()
      end, { buffer = self.buf, desc = "duet: hide the agent terminal" })
    elseif LINK_ACTIONS[action] then
      local spec = LINK_ACTIONS[action]
      local all = { lhs }
      for _, variant in ipairs(spec.variants and spec.variants(lhs) or {}) do
        if not named[vim.keycode(variant)] then
          all[#all + 1] = variant
        end
      end
      for _, key in ipairs(all) do
        vim.keymap.set(spec.modes or "n", key, function()
          spec.fn(key)
        end, { buffer = self.buf, desc = spec.desc })
      end
    end
  end
end

---Follow file links in the terminal: OSC 8 hyperlinks always, and underlining with
---`links.highlight`. Read when the terminal starts.
---@param self duet.Session
local function attach_links(self)
  local links = require("duet.links")
  links.attach_osc8(self.buf)
  if require("duet.config").get().links.highlight then
    links.attach_highlighter(self.buf)
  end
end

---The terminal's screen height: Neovim sizes a terminal to the tallest window showing it, in
---any tab, and keeps that size while no window shows it, so the height last seen stands in
---(also recorded when the terminal leaves a window). The height leaves out a window's winbar,
---and Neovim's autocmd window (`nvim_buf_call` on a hidden buffer) doesn't count, as in Neovim.
---@param self duet.Session
---@return integer rows 0 if no window has shown the terminal
local function screen_rows(self)
  local rows = 0
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    if vim.fn.win_gettype(win) ~= "autocmd" then
      rows = math.max(rows, vim.fn.getwininfo(win)[1].height)
    end
  end
  if rows > 0 then
    self.rows = rows
  end
  return self.rows or 0
end

---@param self duet.Session
local function setup_buffer(self)
  local buf = self.buf
  local term_name = vim.api.nvim_buf_get_name(buf)
  vim.api.nvim_buf_set_name(buf, ("duet://%s/%s"):format(self.agent.name, self.id))
  -- Renaming leaves an unlisted buffer with the old name behind; drop it. Compare names
  -- exactly: bufnr() treats its argument as a pattern and could match another buffer.
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.api.nvim_buf_get_name(other) == term_name then
      pcall(vim.api.nvim_buf_delete, other, { force = true })
    end
  end
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = FILETYPE
  vim.b[buf].duet_session = self.id
  set_keymaps(self)
  attach_links(self)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = buf,
    desc = "duet: enter terminal mode",
    callback = function()
      if config().auto_insert and self.job then
        vim.cmd.startinsert()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = augroup,
    buffer = buf,
    desc = "duet: remember the terminal's height while it is hidden",
    callback = function()
      screen_rows(self)
    end,
  })
  -- BufUnload comes first for :bdelete, :bunload and :bwipeout, so the session is
  -- released before on_exit runs and the exit is not reported as unexpected.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = augroup,
    buffer = buf,
    desc = "duet: forget the session",
    callback = function()
      release(self)
    end,
  })
end

---Run `fn` in a hidden float that shows the session's buffer, sized like the window the
---layout opens, so a job started there gets that screen size: Neovim's autocmd window
---(`nvim_buf_call()`) is only 5 rows tall. The float is opened and closed without autocmds,
---and the size is remembered as the terminal's height (see screen_rows()). Without a float,
---e.g. when the editor can't open one, `fn` runs in the autocmd window.
---@param self duet.Session
---@param fn fun(): any
---@return boolean ok
---@return any result `fn`'s result, or its error
local function call_hidden(self, fn)
  local width, height = M.layout_size(config().layout, config(), editor_size())
  local opened, win = pcall(vim.api.nvim_open_win, self.buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width,
    height = height,
    hide = true,
    focusable = false,
    style = "minimal",
    noautocmd = true,
  })
  if not opened then
    return pcall(vim.api.nvim_buf_call, self.buf, fn)
  end
  -- Closing the buffer's only window would unload it, ending the job, with 'nohidden'.
  vim.bo[self.buf].bufhidden = "hide"
  local ok, result = pcall(vim.api.nvim_win_call, win, fn)
  pcall(vim.cmd, ("noautocmd call nvim_win_close(%d, v:true)"):format(win))
  if ok then
    self.rows = height
  end
  return ok, result
end

---Start the job in `win`, or hidden if `win` is nil (see call_hidden()).
---@param self duet.Session
---@param plan duet.LaunchPlan
---@param win integer|nil
---@return boolean|nil ok
---@return string|nil err
local function spawn(self, plan, win)
  local env = vim.tbl_extend("force", plan.env or {}, { NVIM = M.servername() })
  local job_opts = {
    term = true,
    cwd = self.root,
    env = env,
    on_exit = function(_, code)
      on_exit(self, code)
    end,
  }
  local function run()
    return vim.fn.jobstart(plan.argv, job_opts)
  end
  local ok, job
  if win then
    ok, job = pcall(vim.api.nvim_win_call, win, run)
  else
    ok, job = call_hidden(self, run)
  end
  if not ok then
    return nil, ("terminal: cannot start %s: %s"):format(self.agent.name, (tostring(job):gsub("^Vim:", "")))
  end
  if type(job) ~= "number" or job <= 0 then
    return nil, ("terminal: cannot start %s (jobstart returned %s)"):format(self.agent.name, tostring(job))
  end
  self.job = job
  return true
end

---Throw away a session that never started: its buffer and run dir.
---@param self duet.Session
local function discard(self)
  self.stopping = true
  remove_run_dir(self.run_dir)
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
end

---Hide every other session in the current tab.
---@param self duet.Session
local function hide_others(self)
  for _, other in pairs(sessions) do
    if other ~= self then
      other:hide()
    end
  end
end

---Make the session the one shown in the current tab: hide the others, then give its window
---its size. A split opened while another session's split was still shown only got the room
---that one left (see 'winminwidth').
---@param self duet.Session
---@param win integer the session's window
local function take_screen(self, win)
  hide_others(self)
  fit_split(win, config(), editor_size())
end

---@class duet.SessionOpts
---@field root? string project root (default: M.root())
---@field win? integer start the agent in this window instead of opening one
---@field hidden? boolean start the agent without showing it

---Create a session and start the agent: build the launch spec, ask the adapter for its
---plan, write the plan's files and spawn the job in a terminal buffer.
---@param agent duet.Agent
---@param opts? duet.SessionOpts
---@return duet.Session|nil session
---@return string|nil err
function Session.new(agent, opts)
  opts = opts or {}
  ensure_autocmds()
  local id = new_id()
  local root = opts.root or M.root()
  local run_dir = vim.fs.joinpath(M.run_root(), id)
  ---@type duet.LaunchSpec
  local spec = { cwd = root, session_id = id, run_dir = run_dir }

  local ok, plan = pcall(agent.launch, agent, spec)
  if not ok then
    return nil, ("terminal: %s launch failed: %s"):format(agent.name, plan)
  end
  local plan_err = check_plan(plan)
  if plan_err then
    return nil, plan_err
  end
  local written, write_err = write_files(run_dir, plan.files or {})
  if not written then
    remove_run_dir(run_dir)
    return nil, write_err
  end

  local self = setmetatable({
    id = id,
    agent = agent,
    root = root,
    run_dir = run_dir,
    buf = vim.api.nvim_create_buf(false, false),
    stopping = false,
    stopped = false,
    seen_ready = false,
    exit_seen = false,
    last_used = next_use(),
  }, Session)

  -- Start in a window when there is one, so the TUI gets its size from the start. Other
  -- windows are left alone until the job runs, so a failed start changes nothing on screen.
  local win, prev_buf, opened = opts.win, nil, false
  if win then
    prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, self.buf)
    -- A window duet opened keeps its layout. Any other window, e.g. one of the user's that
    -- showed the terminal, is not made a split: duet would size it as one.
    apply_window_options(win, vim.w[win].duet_layout or (is_float(win) and "float" or nil))
    record_size(win)
  elseif not opts.hidden then
    local open_err
    win, open_err = open_window(self.buf, title(agent))
    if not win then
      discard(self)
      return nil, open_err
    end
    opened = true
  end

  local started, err = spawn(self, plan, win)
  if not started then
    if opened then
      pcall(vim.api.nvim_win_close, win, true)
    elseif vim.api.nvim_win_is_valid(win) then
      -- Put the previous buffer back, or an empty one if it is gone, so deleting ours
      -- below does not close a window we were lent.
      local keep = prev_buf and vim.api.nvim_buf_is_valid(prev_buf) and prev_buf or vim.api.nvim_create_buf(true, false)
      pcall(vim.api.nvim_win_set_buf, win, keep)
    end
    discard(self)
    return nil, err
  end
  require("duet.log").debug("session %s: started %s in %s", id, table.concat(plan.argv, " "), root)
  sessions[id] = self
  setup_buffer(self)
  require("duet.watch").refresh()
  if win then
    take_screen(self, win)
  end
  return self
end

---Whether the agent is still running.
---@return boolean
function Session:is_running()
  return self.job ~= nil
end

---The session's window in the current tab, if it is shown there.
---@return integer|nil
function Session:window()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
  return nil
end

---Whether the session is shown in the current tab.
---@return boolean
function Session:is_visible()
  return self:window() ~= nil
end

---The terminal's last `n` lines, trailing blank lines left out. A TUI that renders inline
---leaves the rows below its output blank.
---With `rows`, the screen's height, above `n`: from the screen's top row instead, or the last
---`n` lines if they reach higher (output that ends near the top of a tall screen).
---@param buf integer
---@param n integer
---@param rows? integer
---@return string[]
local function last_lines(buf, n, rows)
  -- Find the last non-blank line, reading back a block at a time: a tall terminal can
  -- have many blank rows below the output.
  local count = vim.api.nvim_buf_line_count(buf)
  local last = count
  local block = 100
  while last > 0 do
    local first = math.max(0, last - block)
    local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local i = #lines
    while i > 0 and vim.trim(lines[i]) == "" do
      i = i - 1
    end
    if i > 0 then
      last = first + i
      break
    end
    last = first
  end
  local first = last - n
  if rows and rows > n then
    first = math.min(first, count - rows)
  end
  return vim.api.nvim_buf_get_lines(buf, math.max(0, first), last, false)
end

---The terminal's lines the adapter's is_ready and read_input see: its screen down to the
---last non-blank row, or the last READY_LINES non-blank lines if they reach higher.
---@param self duet.Session
---@return string[]
local function ready_lines(self)
  return last_lines(self.buf, READY_LINES, screen_rows(self))
end

---Why the session's agent no longer runs in its terminal, or nil while it does.
---@param self duet.Session
---@return string|nil err the agent exited, or was stopped
local function gone(self)
  if sessions[self.id] == self and self.job and vim.api.nvim_buf_is_valid(self.buf) then
    return nil
  end
  local name = self.agent.name
  if self.stopped then
    return ("terminal: %s was stopped"):format(name)
  elseif self.seen_ready then
    return ("terminal: %s exited"):format(name)
  end
  return ("terminal: %s exited before it was ready for input"):format(name)
end

---Whether the agent's TUI accepts input now, as the adapter's `is_ready` tells from the
---terminal's screen (see ready_lines): false while it starts up or shows a dialog. An agent without
---`is_ready` is ready whenever it runs.
---@return boolean|nil ready
---@return string|nil err the agent is gone, or the adapter's is_ready failed
function Session:is_ready()
  local err = gone(self)
  if err then
    return nil, err
  end
  local ready = true
  if self.agent.is_ready then
    local ok, result = pcall(self.agent.is_ready, self.agent, ready_lines(self))
    if not ok then
      return nil, ("terminal: %s is_ready failed: %s"):format(self.agent.name, result)
    end
    ready = result == true
  end
  self.seen_ready = self.seen_ready or ready
  return ready
end

---What the agent's input box holds now, as the adapter's `read_input` reads it from the
---terminal's screen (see ready_lines): nil if no input box is on screen, or if the adapter has no
---`read_input`, the agent is gone, or `read_input` failed (`err` tells which of the last two).
---@return string|nil input
---@return string|nil err
function Session:input()
  if not self.agent.read_input then
    return nil
  end
  local err = gone(self)
  if err then
    return nil, err
  end
  local ok, result = pcall(self.agent.read_input, self.agent, ready_lines(self))
  if not ok then
    return nil, ("terminal: %s read_input failed: %s"):format(self.agent.name, result)
  end
  return type(result) == "string" and result or nil
end

---Call `check` now and then every few milliseconds, without blocking, until it returns
---true or an error, then call `cb` with that error. After `timeout_ms`, `cb` gets
---`timed_out = true` instead.
---@param timeout_ms integer
---@param check fun(): boolean|nil, string|nil
---@param cb fun(err?: string, timed_out?: boolean)
function Session:poll(timeout_ms, check, cb)
  local passed, err = check()
  if passed or err then
    cb(err)
    return
  end
  local timer, timer_err = vim.uv.new_timer()
  if not timer then
    cb(("terminal: cannot start a timer: %s"):format(tostring(timer_err)))
    return
  end
  local deadline = vim.uv.now() + timeout_ms
  local done = false
  local function finish(finish_err, timed_out)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    cb(finish_err, timed_out)
  end
  timer:start(
    READY_POLL_MS,
    READY_POLL_MS,
    vim.schedule_wrap(function()
      if done then
        return
      end
      local now_passed, check_err = check()
      if now_passed or check_err then
        finish(check_err)
      elseif vim.uv.now() >= deadline then
        finish(nil, true)
      end
    end)
  )
end

---Call `cb` once the agent's TUI accepts input (see Session:is_ready). Polls without
---blocking; `cb` gets an error after `timeout_ms` (with `timed_out` set), or if the job
---exits or is stopped first.
---@param timeout_ms integer
---@param cb fun(err?: string, timed_out?: boolean)
function Session:when_ready(timeout_ms, cb)
  self:poll(timeout_ms, function()
    return self:is_ready()
  end, function(err, timed_out)
    if timed_out then
      err = ("terminal: %s is not ready for input after %d ms (answer its prompt in the terminal, then try again)"):format(
        self.agent.name,
        timeout_ms
      )
    end
    cb(err, timed_out)
  end)
end

---Show the session in the current tab, hiding any other duet session there. Focus does not move.
---@return integer|nil win
---@return string|nil err
function Session:show()
  self.last_used = next_use()
  local win = self:window()
  if not win then
    local err
    win, err = open_window(self.buf, title(self.agent))
    if not win then
      return nil, err
    end
    take_screen(self, win)
  end
  if not self.job then
    self.exit_seen = true
  end
  return win
end

---Show the session and move the cursor into it (in terminal mode with `auto_insert`).
---@return integer|nil win
---@return string|nil err
function Session:focus()
  local win, err = self:show()
  if not win then
    return nil, err
  end
  vim.api.nvim_set_current_win(win)
  if config().auto_insert and self.job then
    vim.cmd.startinsert()
  end
  return win
end

---Hide the session's window in the current tab. The job keeps running.
---@return boolean|nil ok
---@return string|nil err e.g. E11 in the command-line window
function Session:hide()
  local win = self:window()
  if not win then
    return true
  end
  local ok, err = close_window(win, self.buf)
  if not ok then
    return nil, ("terminal: cannot hide %s: %s"):format(self.agent.name, err)
  end
  return true
end

---Show the session if it is hidden in the current tab, hide it otherwise.
---@return boolean|nil ok
---@return string|nil err
function Session:toggle()
  if self:is_visible() then
    return self:hide()
  end
  local win, err = self:focus()
  return win and true, err
end

---Stop the agent and wipe its buffer. The run dir is removed. The agent is stopped even
---if the buffer can't be wiped (e.g. E11 in the command-line window).
---@return boolean|nil ok
---@return string|nil err
function Session:stop()
  release(self)
  if vim.api.nvim_buf_is_valid(self.buf) then
    close_windows(self)
    local ok, err = pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    if not ok then
      return nil, ("terminal: cannot close %s's buffer: %s"):format(self.agent.name, err)
    end
  end
  return true
end

---Start a new session for the same agent and root, then stop this one. The new session
---takes over this one's window if it is shown, and starts hidden otherwise; focus does not
---move. Reads the adapter and config again. If the new session fails to start, this one
---is left as it was.
---@return duet.Session|nil session the new session
---@return string|nil err
function Session:restart()
  local agent, err = require("duet.agents").get(self.agent.name)
  if not agent then
    return nil, err
  end
  local win = self:window()
  local new, new_err = Session.new(agent, { root = self.root, win = win, hidden = win == nil })
  if not new then
    return nil, new_err
  end
  self:stop()
  return new
end

-- Module API ----------------------------------------------------------------

---Session by id (see `b:duet_session`).
---@param id string
---@return duet.Session|nil
function M.get(id)
  return sessions[id]
end

---All sessions, most recently used first.
---@return duet.Session[]
function M.list()
  local list = vim.tbl_values(sessions)
  table.sort(list, function(a, b)
    return a.last_used > b.last_used
  end)
  return list
end

---The session of `agent` for `root`.
---@param name string agent name
---@param root string
---@return duet.Session|nil
function M.find(name, root)
  for _, session in pairs(sessions) do
    if session.agent.name == name and session.root == root then
      return session
    end
  end
  return nil
end

---The session for the current context: the one in the current buffer, else the most
---recently used one for the current project root. Never creates a session.
---@return duet.Session|nil
function M.current()
  local id = vim.b.duet_session
  if id and sessions[id] then
    return sessions[id]
  end
  local root = M.root()
  for _, session in ipairs(M.list()) do
    if session.root == root then
      return session
    end
  end
  return nil
end

---The visible duet session in the current tab, if any.
---@return duet.Session|nil
local function visible()
  for _, session in ipairs(M.list()) do
    if session:is_visible() then
      return session
    end
  end
  return nil
end

---The session that commands act on: `name`'s session for the current root, or with no
---name the visible one, then current(). Never starts a session; one started for the
---commands gets the root `root()`.
---@param name? string agent name
---@return duet.Session|nil
function M.target(name)
  if name then
    return M.find(name, M.root())
  end
  return visible() or M.current()
end

local target = M.target

---Open and focus the agent's session for the current root, starting it if needed.
---A session whose agent has exited is restarted, unless its terminal has not been seen
---since the exit: then it is shown, so the agent's last output can be read.
---@param name? string agent name (default: the current session's agent, else the `agent` option)
---@return duet.Session|nil
---@return string|nil err
function M.open(name)
  local session, err = target(name), nil
  if session and not session:is_running() and session.exit_seen then
    session, err = session:restart()
  elseif not session then
    local agent
    agent, err = require("duet.agents").get(name)
    if agent then
      session, err = Session.new(agent)
    end
  end
  if not session then
    return nil, err
  end
  local win, focus_err = session:focus()
  if not win then
    return nil, focus_err
  end
  return session
end

---The agent's running session for the current root, started if there is none, or restarted
---if its agent has exited. Focus does not move. As with M.open, an exited session whose
---terminal has not been seen since the exit is not restarted: it is shown, so the agent's
---last output can be read, and an error is returned.
---@param name? string agent name (default: the current session's agent, else the `agent` option)
---@param opts? { show?: boolean } show the session if this call starts it (default: false)
---@return duet.Session|nil
---@return string|nil err
function M.ensure(name, opts)
  opts = opts or {}
  local session, err = target(name), nil
  if session and session:is_running() then
    return session
  end
  if session and not session.exit_seen then
    local win, show_err = session:show()
    if not win then
      return nil, show_err
    end
    return nil, ("terminal: %s exited: see its terminal, then try again"):format(session.agent.name)
  end
  if session then
    session, err = session:restart()
  else
    local agent
    agent, err = require("duet.agents").get(name)
    if agent then
      session, err = Session.new(agent, { hidden = not opts.show })
    end
  end
  if not session then
    return nil, err
  end
  if opts.show then
    local win, show_err = session:show()
    if not win then
      return nil, show_err
    end
  end
  return session
end

---Hide the session if it is visible in the current tab, otherwise open it.
---@param name? string agent name
---@return duet.Session|nil
---@return string|nil err
function M.toggle(name)
  local session = target(name)
  if session and session:is_visible() then
    local ok, err = session:hide()
    if not ok then
      return nil, err
    end
    return session
  end
  return M.open(name)
end

---Hide the session, or stop it with `opts.stop`.
---@param opts? { stop?: boolean, agent?: string }
---@return boolean|nil ok
---@return string|nil err
function M.close(opts)
  opts = opts or {}
  local session = target(opts.agent)
  if not session then
    if opts.agent then
      return nil, ("terminal: no %s session for this project"):format(opts.agent)
    end
    return nil, "terminal: no agent session"
  end
  if opts.stop then
    return session:stop()
  end
  return session:hide()
end

---Restart the session, or start one if there is none.
---@param name? string agent name
---@return duet.Session|nil
---@return string|nil err
function M.restart(name)
  local session = target(name)
  if not session then
    return M.open(name)
  end
  local new, err = session:restart()
  if not new then
    return nil, err
  end
  local win, focus_err = new:focus()
  if not win then
    return nil, focus_err
  end
  return new
end

---Stop every session and remove its run dir, synchronously. Runs on VimLeavePre.
function M.stop_all()
  for _, session in ipairs(M.list()) do
    release(session)
  end
end

-- Command handlers ------------------------------------------------------------

---Wrap an API function that takes an agent name as a :Duet subcommand handler.
---@param fn fun(name?: string): any, string?
---@return fun(args: string[], opts?: duet.CommandOpts): boolean|nil, string|nil
local function with_agent(fn)
  return function(args)
    local result, err = fn(args[1])
    if result == nil then
      return nil, err
    end
    return true
  end
end

---`:Duet toggle [agent]`. Returns `true`, or `nil` and an error.
---@type fun(args: string[], opts?: duet.CommandOpts): boolean|nil, string|nil
M.cmd_toggle = with_agent(M.toggle)

---`:Duet open [agent]`. Returns `true`, or `nil` and an error.
---@type fun(args: string[], opts?: duet.CommandOpts): boolean|nil, string|nil
M.cmd_open = with_agent(M.open)

---`:Duet restart [agent]`. Returns `true`, or `nil` and an error.
---@type fun(args: string[], opts?: duet.CommandOpts): boolean|nil, string|nil
M.cmd_restart = with_agent(M.restart)

---`:Duet[!] close [agent]`: hide the session, or stop it with `!`.
---@param args string[]
---@param opts? duet.CommandOpts
---@return boolean|nil
---@return string|nil err
function M.cmd_close(args, opts)
  return M.close({ stop = (opts or {}).bang, agent = args[1] })
end

return M
