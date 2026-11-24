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
local Session = {}
Session.__index = Session
M.Session = Session

---@type table<string, duet.Session>
local sessions = {}
local id_counter = 0
local use_counter = 0
---@type integer|nil
local augroup

local FILETYPE = "duet_terminal"

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
    return { split = "below", win = -1, height = M.resolve_size(opts.split.height, lines) }
  end
  return { split = layout, win = -1, width = M.resolve_size(opts.split.width, columns) }
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

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

---Set the terminal's window options. They are local to the window's current buffer
---(`vim.wo[win][0]`, like :setlocal), so call this again after putting a new buffer in
---the window. `w:duet_layout` records the layout for resizing.
---@param win integer
---@param layout "float"|"right"|"left"|"bottom"
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
  if layout == "bottom" then
    wo.winfixheight = true
  elseif layout ~= "float" then
    wo.winfixwidth = true
  end
  vim.w[win].duet_layout = layout
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
  return win
end

---@param agent duet.Agent
---@return string
local function title(agent)
  return (" %s "):format(agent.name)
end

---On VimResized: centre and size floats again, and give splits with a fractional size
---their share of the new editor size. Absolute split sizes are left alone, so a split the
---user resized by hand keeps its size.
local function relayout()
  local opts = config()
  local editor = editor_size()
  for _, session in pairs(sessions) do
    for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
      if is_float(win) then
        -- Use the border the window has, which a later setup() may have changed in config.
        -- Neovim 0.11 leaves `border` out of the config of a window without one.
        local border = vim.api.nvim_win_get_config(win).border or "none"
        local float = vim.tbl_extend("force", opts.float, { border = border })
        local cfg = M.win_config("float", vim.tbl_extend("force", opts, { float = float }), editor)
        cfg.title, cfg.title_pos, cfg.border = nil, nil, nil
        vim.api.nvim_win_set_config(win, cfg)
      elseif vim.w[win].duet_layout == "bottom" then
        if opts.split.height <= 1 then
          vim.api.nvim_win_set_height(win, M.resolve_size(opts.split.height, editor.lines))
        end
      elseif vim.w[win].duet_layout and opts.split.width <= 1 then
        vim.api.nvim_win_set_width(win, M.resolve_size(opts.split.width, editor.columns))
      end
    end
  end
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
    callback = relayout,
  })
end

---Mark the job as stopped by duet and clean up now. Safe to call more than once.
---@param self duet.Session
local function release(self)
  self.stopping = true
  sessions[self.id] = nil
  if self.job then
    pcall(vim.fn.jobstop, self.job)
  end
  remove_run_dir(self.run_dir)
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

---Why a job exited with `code`, in words. Pure. Neovim reports a job killed by signal N
---as 128 + N.
---@param code integer non-zero exit code
---@return string
function M.exit_reason(code)
  if code > 128 then
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
---@param hidden boolean the terminal is kept but not shown, so say how to see it
---@return string
function M.exit_message(name, code, lines, hidden)
  local parts = { ("%s exited with code %d: %s"):format(name, code, M.exit_reason(code)) }
  vim.list_extend(parts, lines)
  if hidden then
    parts[#parts + 1] = "Run :Duet open to see the output."
  end
  return table.concat(parts, "\n")
end

---Whether `close_on_exit` closes the terminal after an exit with `code`.
---@param code integer
---@return boolean
local function closes_on(code)
  local policy = config().close_on_exit
  return policy == "always" or (policy == "success" and code == 0)
end

---@param self duet.Session
---@param code integer
local function on_exit(self, code)
  self.job = nil
  self.exit_code = code
  remove_run_dir(self.run_dir)
  if self.stopping then
    return
  end
  require("duet.log").debug("session %s (%s) exited with code %d", self.id, self.agent.name, code)
  local valid = vim.api.nvim_buf_is_valid(self.buf)
  local close = closes_on(code)
  local shown = valid and #vim.fn.win_findbuf(self.buf) > 0
  if code ~= 0 then
    local lines = valid and M.tail(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), TAIL_LINES) or {}
    local msg = M.exit_message(self.agent.name, code, lines, valid and not close and not shown)
    require("duet.util").notify(msg, vim.log.levels.ERROR)
  end
  if not valid then
    return
  end
  if close then
    -- BufUnload releases the session.
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    return
  end
  self.exit_seen = shown
  -- In terminal mode, the next key would close the exited terminal and its output.
  if vim.api.nvim_get_current_buf() == self.buf and vim.api.nvim_get_mode().mode == "t" then
    vim.cmd.stopinsert()
  end
end

---@param self duet.Session
local function set_keymaps(self)
  for lhs, action in pairs(config().keys) do
    if action == "normal_mode" then
      vim.keymap.set("t", lhs, [[<C-\><C-n>]], { buffer = self.buf, desc = "duet: leave terminal mode" })
    elseif action == "hide" then
      vim.keymap.set({ "t", "n" }, lhs, function()
        self:hide()
      end, { buffer = self.buf, desc = "duet: hide the agent terminal" })
    end
  end
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

---Start the job in `win`, or in the hidden buffer if `win` is nil.
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
    ok, job = pcall(vim.api.nvim_buf_call, self.buf, run)
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
    exit_seen = false,
    last_used = next_use(),
  }, Session)

  -- Start in a window when there is one, so the TUI gets its size from the start. Other
  -- windows are left alone until the job runs, so a failed start changes nothing on screen.
  local win, prev_buf, opened = opts.win, nil, false
  if win then
    prev_buf = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, self.buf)
    apply_window_options(win, vim.w[win].duet_layout or (is_float(win) and "float" or config().layout))
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
  if win then
    hide_others(self)
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
    hide_others(self)
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

---Hide the session's window in the current tab. The job keeps running.
---@return boolean|nil ok
---@return string|nil err e.g. E11 in the command-line window
function Session:hide()
  local win = self:window()
  if not win then
    return true
  end
  local ok, err
  if is_last_window(win) then
    local alt = vim.api.nvim_win_call(win, function()
      return vim.fn.bufnr("#")
    end)
    if alt <= 0 or alt == self.buf or not vim.bo[alt].buflisted then
      alt = vim.api.nvim_create_buf(true, false)
    end
    ok, err = pcall(vim.api.nvim_win_set_buf, win, alt)
  else
    ok, err = pcall(vim.api.nvim_win_close, win, false)
  end
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

---Find the session to act on: `name`'s session for the current root, or with no name
---the visible one, then current().
---@param name? string
---@return duet.Session|nil
local function target(name)
  if name then
    return M.find(name, M.root())
  end
  return visible() or M.current()
end

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
