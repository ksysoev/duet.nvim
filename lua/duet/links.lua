---@brief File links in agent output: find `path:line` references in terminal text, resolve
--- them against the session's root and open them in a code window. See |duet-links|.
---
--- `parse()` is pure. `resolve()` only touches the filesystem. The rest is thin UI around
--- them: the keys in duet terminals, the optional highlighter and OSC 8 hyperlinks.

local M = {}

---@class duet.Link
---@field path string the path as written, without a leading `@`; `~` is expanded by resolve()
---@field line? integer 1-based line
---@field end_line? integer last line of a range
---@field col? integer 1-based column
---@field s integer 1-based byte column where the reference starts in the text
---@field e integer 1-based byte column where it ends (inclusive)
---@field row? integer 1-based buffer row, set by the buffer functions
---@field abs? string absolute path, set once resolved

local FLASH_MS = 300

local hl_ns = vim.api.nvim_create_namespace("duet.links")
local flash_ns = vim.api.nvim_create_namespace("duet.links.flash")
local osc8_ns = vim.api.nvim_create_namespace("duet.links.osc8")

---OSC 8 spans by buffer, then by extmark id.
---@type table<integer, table<integer, { uri: string, text: string }>>
local osc8_spans = {}

-- Parsing --------------------------------------------------------------------

-- Characters that end a token. Any 3-byte UTF-8 sequence starting with 0xE2 (U+2000 to
-- U+2FFF: punctuation, arrows, box drawing, shapes, dingbats such as "⏺ ⎿ │ ● … ’") and
-- U+00A0 also end one; they are blanked in a copy of the line so byte columns stay put.
local TOKEN = "()([^%s\"'`%(%)%[%]{}<>,;|]+)()"

---@param line string
---@return string
local function blank_symbols(line)
  return (line:gsub("\226[\128-\191][\128-\191]", "   "):gsub("\194\160", "  "))
end

-- Location suffixes, tried in order. Each returns path, line, end_line, col.
local SUFFIXES = {
  function(t)
    local p, l, e = t:match("^(.-)#L(%d+)%-L?(%d+)$")
    return p, l, e, nil
  end,
  function(t)
    local p, l, c = t:match("^(.-)#L(%d+)C(%d+)$")
    return p, l, nil, c
  end,
  function(t)
    local p, l = t:match("^(.-)#L(%d+)$")
    return p, l, nil, nil
  end,
  function(t)
    local p, l, e = t:match("^(.-):L?(%d+)%-L?(%d+)$")
    return p, l, e, nil
  end,
  function(t)
    local p, l, c = t:match("^(.-):L?(%d+):(%d+)$")
    return p, l, nil, c
  end,
  function(t)
    local p, l = t:match("^(.-):L?(%d+)$")
    return p, l, nil, nil
  end,
}

---Split a reference like `a.lua:10-20` into its path and location.
---@param token string
---@return string path
---@return integer|nil line
---@return integer|nil end_line
---@return integer|nil col
local function split_location(token)
  for _, try in ipairs(SUFFIXES) do
    local p, l, e, c = try(token)
    if p and p ~= "" then
      return p, tonumber(l), tonumber(e), tonumber(c)
    end
  end
  return token, nil, nil, nil
end

---A `file://` URI as a path, or nil if `token` is not one.
---@param token string
---@return string|nil
local function file_uri_path(token)
  local rest = token:match("^file://[^/]*(/.*)$")
  return rest and vim.uri_decode(rest) or nil
end

---Whether `path` looks enough like a file to be worth resolving.
---@param path string
---@param marked boolean written with `@` or in backticks
---@param located boolean followed by a line number
---@return boolean
local function plausible(path, marked, located)
  if not path:find("%a") then
    return false -- "10:30", "..", "/"
  end
  if marked or located then
    return true
  end
  return path:find("/") ~= nil or path:find("%.[%w_-]*%a[%w_-]*$") ~= nil
end

---Parse one reference without surrounding text: a path with an optional location, or a
---`file://` URI. Other URLs give nil.
---@param token string
---@param marked? boolean written with `@` or in backticks: bare names count
---@return { path: string, line?: integer, end_line?: integer, col?: integer }|nil
function M.parse_ref(token, marked)
  local uri_path = file_uri_path(token)
  if uri_path then
    token = uri_path
    marked = true
  elseif token:find("://", 1, true) then
    return nil -- a URL
  end
  local path, line, end_line, col = split_location(token)
  if not plausible(path, marked == true, line ~= nil) then
    return nil
  end
  if end_line and line and end_line < line then
    line, end_line = end_line, line
  end
  if end_line == line then
    end_line = nil
  end
  return { path = path, line = line, end_line = end_line, col = col }
end

---Find the file references in a line of text, e.g. `lua/duet/init.lua:10`,
---`a.go:12:3`, `a.lua:L10-L20`, `a.lua#L10`, `@a.lua (lines 3-5)`, `` `Makefile` ``,
---`File "a.py", line 10` or `file:///abs/a.lua#L3`. URLs are skipped. Candidates are not
---checked against the filesystem: see resolve().
---@param line string
---@return duet.Link[] links in order of appearance
function M.parse(line)
  local links = {}
  local scan = blank_symbols(line)
  local last_e = 0
  for s, raw, after in scan:gmatch(TOKEN) do
    local e = after - 1
    if s > last_e then
      -- Strip punctuation around the reference; `@` marks one.
      local lead = raw:match("^%**@?%**")
      local trimmed = raw:sub(#lead + 1)
      local trail = trimmed:match("[.,:;!?*]*$")
      trimmed = trimmed:sub(1, #trimmed - #trail)
      local ts, te = s + #lead, e - #trail
      local at = lead:find("@", 1, true) ~= nil
      local backticked = line:sub(ts - 1, ts - 1) == "`" and line:sub(te + 1, te + 1) == "`"
      local ref = trimmed ~= "" and M.parse_ref(trimmed, at or backticked) or nil
      if ref then
        -- A location written after the path: `@a.lua (lines 3-5)`, `"a.py", line 10`.
        local rest = line:sub(te + 1)
        local l1, l2, phrase_end
        local p_start, p_end, a, b = rest:find("^ %(lines? (%d+)%-?(%d*)%)")
        if not p_start then
          p_start, p_end, a = rest:find("^[\"']?,%s*line%s+(%d+)")
        end
        if p_start and not ref.line then
          l1, l2, phrase_end = tonumber(a), tonumber(b), te + p_end
          ref.line = l1
          if l2 and l2 > l1 then
            ref.end_line = l2
          end
        end
        links[#links + 1] = {
          path = ref.path,
          line = ref.line,
          end_line = ref.end_line,
          col = ref.col,
          s = at and (ts - 1) or ts,
          e = phrase_end or te,
        }
        last_e = phrase_end or te
      end
    end
  end
  return links
end

-- Resolving ------------------------------------------------------------------

---Find the file a link refers to: absolute paths and `~` as they are, relative ones
---against `cwd`, then the git root that contains `cwd`. Directories count.
---@param path string
---@param cwd? string default: the current working directory
---@return string|nil abs normalized absolute path
---@return string|nil err
function M.resolve(path, cwd)
  local expanded = path
  if path == "~" or vim.startswith(path, "~/") then
    expanded = vim.fs.normalize(path)
  end
  local candidates = {}
  if vim.startswith(expanded, "/") then
    candidates[1] = expanded
  else
    cwd = vim.fs.normalize(vim.fs.abspath(cwd or vim.uv.cwd() or "."))
    candidates[1] = vim.fs.joinpath(cwd, expanded)
    local root = require("duet.util").git_root(cwd)
    if root and root ~= cwd then
      candidates[2] = vim.fs.joinpath(root, expanded)
    end
  end
  for _, candidate in ipairs(candidates) do
    if vim.uv.fs_stat(candidate) then
      return vim.fs.normalize(candidate), nil
    end
  end
  return nil, ("links: no such file '%s'"):format(path)
end

-- Buffers --------------------------------------------------------------------

---The root that paths in `buf` are relative to: its duet session's root, else the one a
---new session would get.
---@param buf integer
---@return string
function M.cwd(buf)
  local terminal = require("duet.terminal")
  local id = vim.b[buf].duet_session
  local session = id and terminal.get(id)
  return session and session.root or terminal.root()
end

---@param buf integer
---@param row integer 1-based
---@return string
local function get_line(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
end

---Links in `lines` (starting at buffer row `first`) that resolve, with `row` and `abs`.
---@param lines string[]
---@param first integer
---@param cwd string
---@return duet.Link[]
local function resolved_links(lines, first, cwd)
  local cache = {}
  local found = {}
  for i, text in ipairs(lines) do
    for _, link in ipairs(M.parse(text)) do
      if cache[link.path] == nil then
        cache[link.path] = M.resolve(link.path, cwd) or false
      end
      if cache[link.path] then
        link.row, link.abs = first + i - 1, cache[link.path]
        found[#found + 1] = link
      end
    end
  end
  return found
end

---Text of the buffer between two (0-based row, 0-based col) positions on one row.
---@param buf integer
---@param row integer
---@param s integer
---@param e integer end, exclusive
---@return string
local function slice(buf, row, s, e)
  local ok, text = pcall(vim.api.nvim_buf_get_text, buf, row, s, row, e, {})
  return ok and text[1] or ""
end

---The OSC 8 hyperlink at a (1-based row, 1-based byte col) position, as a link.
---@param buf integer
---@param row integer
---@param col integer
---@param cwd string
---@return duet.Link|nil
local function osc8_at(buf, row, col, cwd)
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    osc8_ns,
    { row - 1, 0 },
    { row - 1, -1 },
    { details = true, overlap = true }
  )
  local spans = osc8_spans[buf] or {}
  for _, mark in ipairs(marks) do
    local id, r, s, details = mark[1], mark[2], mark[3], mark[4]
    local span = spans[id]
    local e = details.end_col
    -- Output rewritten over the span makes it stale: its text must still be there.
    if span and e and s < col and col <= e and slice(buf, r, s, e) == span.text then
      local ref = M.parse_ref(span.uri, true)
      if ref then
        local abs = M.resolve(ref.path, cwd)
        if abs then
          return {
            path = ref.path,
            line = ref.line,
            end_line = ref.end_line,
            col = ref.col,
            s = s + 1,
            e = e,
            row = row,
            abs = abs,
          }
        end
      end
    end
  end
  return nil
end

---The link under the cursor in `win`, resolved. An OSC 8 hyperlink there comes first.
---@param win? integer default: the current window
---@return duet.Link|nil link
---@return string|nil err a link that does not resolve, or no link at all
function M.at_cursor(win)
  win = win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1], cursor[2] + 1
  local cwd = M.cwd(buf)
  local osc8 = osc8_at(buf, row, col, cwd)
  if osc8 then
    return osc8
  end
  for _, link in ipairs(M.parse(get_line(buf, row))) do
    if link.s <= col and col <= link.e then
      local abs, err = M.resolve(link.path, cwd)
      if not abs then
        return nil, err
      end
      link.row, link.abs = row, abs
      return link
    end
  end
  return nil, "links: no file link under the cursor"
end

---The first and last buffer rows shown in `win`.
---@param win integer
---@return integer first
---@return integer last
local function visible_rows(win)
  local rows = vim.api.nvim_win_call(win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  return rows[1], rows[2]
end

---Links in the lines `win` shows that resolve, in order.
---@param win? integer default: the current window
---@return duet.Link[]
function M.visible(win)
  win = win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local first, last = visible_rows(win)
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  return resolved_links(lines, first, M.cwd(buf))
end

-- Opening --------------------------------------------------------------------

local function define_highlights()
  vim.api.nvim_set_hl(0, "DuetLink", { link = "Underlined", default = true })
  vim.api.nvim_set_hl(0, "DuetLinkFlash", { link = "IncSearch", default = true })
end

local hl_autocmd
local function ensure_highlights()
  define_highlights()
  if not hl_autocmd then
    hl_autocmd = vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("duet.links.hl", { clear = true }),
      desc = "duet: define link highlights",
      callback = define_highlights,
    })
  end
end

-- Splits a new code window opens with, by the layout of the terminal it opens from: the
-- file goes on the other side.
local SPLIT_FROM = { right = "leftabove vnew", left = "rightbelow vnew", bottom = "leftabove new" }

---The window to open a file in: a code window in the tab, else a new split. A floating
---duet terminal in front is hidden first, so the file is not opened under it.
---@return integer win
local function target_window()
  local util = require("duet.util")
  local cur = vim.api.nvim_get_current_win()
  local id = vim.b.duet_session
  if id and vim.api.nvim_win_get_config(cur).relative ~= "" then
    local session = require("duet.terminal").get(id)
    if session then
      session:hide()
      cur = vim.api.nvim_get_current_win()
    end
  end
  local win, found = util.code_window()
  if found then
    return win
  end
  vim.cmd(SPLIT_FROM[vim.w[cur].duet_layout] or "leftabove vnew")
  return vim.api.nvim_get_current_win()
end

---@param value integer
---@param low integer
---@param high integer
---@return integer
local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

---Open a link in a code window (see |duet-links| for which one), put the cursor on its
---line and column, center the view and briefly highlight the line or range. The window
---is focused.
---@param link duet.Link|{ path: string, line?: integer, end_line?: integer, col?: integer, abs?: string }
---@param opts? { cwd?: string } where a relative, unresolved path is resolved from
---@return boolean|nil ok
---@return string|nil err
function M.open(link, opts)
  local abs, err = link.abs, nil
  if not abs then
    abs, err = M.resolve(link.path, (opts or {}).cwd or M.cwd(0))
    if not abs then
      return nil, err
    end
  end
  ensure_highlights()
  local win = target_window()
  vim.api.nvim_set_current_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) ~= abs then
    vim.cmd("normal! m'")
    local ok, edit_err = pcall(vim.cmd.edit, vim.fn.fnameescape(abs))
    if not ok then
      return nil, ("links: cannot open '%s': %s"):format(link.path, edit_err)
    end
    buf = vim.api.nvim_win_get_buf(win)
  elseif link.line then
    vim.cmd("normal! m'")
  end
  if not link.line or vim.fn.isdirectory(abs) == 1 then
    return true
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local first = clamp(link.line, 1, count)
  local last = clamp(link.end_line or first, first, count)
  local text = get_line(buf, first)
  if link.col then
    vim.api.nvim_win_set_cursor(win, { first, clamp(link.col - 1, 0, math.max(#text - 1, 0)) })
    vim.cmd("normal! zvzz")
  else
    vim.api.nvim_win_set_cursor(win, { first, 0 })
    vim.cmd("normal! zv^zz")
  end
  vim.hl.range(buf, flash_ns, "DuetLinkFlash", { first - 1, 0 }, { last - 1, 0 }, {
    regtype = "V",
    timeout = FLASH_MS,
  })
  return true
end

---Open the link under the cursor (the `"open_link"` key action). Problems are shown
---with a notification.
function M.follow()
  local link, err = M.at_cursor()
  if link then
    link, err = M.open(link)
  end
  if not link then
    require("duet.util").notify(err or "links: nothing to open", vim.log.levels.WARN)
  end
end

---Move the cursor to the next (`dir` 1) or previous (`dir` -1) link in the visible
---lines, `count` times (the `"next_link"` and `"prev_link"` key actions).
---@param dir 1|-1
---@param count? integer default: v:count1
function M.jump(dir, count)
  count = count or vim.v.count1
  local win = vim.api.nvim_get_current_win()
  local links = M.visible(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1], cursor[2] + 1
  local target
  for _ = 1, count do
    local step
    if dir > 0 then
      for _, link in ipairs(links) do
        if link.row > row or (link.row == row and link.s > col) then
          step = link
          break
        end
      end
    else
      for i = #links, 1, -1 do
        local link = links[i]
        if link.row < row or (link.row == row and link.s < col) then
          step = link
          break
        end
      end
    end
    if not step then
      break
    end
    target, row, col = step, step.row, step.s
  end
  if not target then
    require("duet.util").notify(
      ("links: no %s link in the visible output"):format(dir > 0 and "next" or "previous"),
      vim.log.levels.WARN
    )
    return
  end
  vim.api.nvim_win_set_cursor(win, { target.row, target.s - 1 })
end

-- Highlighting ---------------------------------------------------------------

---Underline the links that resolve in every window showing `buf`.
---@param buf integer
function M.highlight(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    for _, link in ipairs(M.visible(win)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, link.row - 1, link.s - 1, {
        end_col = link.e,
        hl_group = "DuetLink",
      })
    end
  end
end

---Keep the links in `buf` underlined while its output changes or it scrolls, at most once
---per `links.debounce_ms`. Stops when the buffer is unloaded.
---@param buf integer
function M.attach_highlighter(buf)
  local timer = assert(vim.uv.new_timer())
  local group = vim.api.nvim_create_augroup("duet.links.buf" .. buf, { clear = true })
  local function schedule()
    local delay = require("duet.config").get().links.debounce_ms
    timer:stop()
    timer:start(delay, 0, function()
      vim.schedule(function()
        M.highlight(buf)
      end)
    end)
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedT", "BufWinEnter" }, {
    group = group,
    buffer = buf,
    desc = "duet: highlight links",
    callback = schedule,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    desc = "duet: highlight links",
    callback = function()
      for key in pairs(vim.v.event) do
        local win = tonumber(key)
        if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
          schedule()
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = buf,
    desc = "duet: stop highlighting links",
    callback = function()
      timer:stop()
      timer:close()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  schedule()
end

-- OSC 8 ----------------------------------------------------------------------

-- How long after an OSC 8 link ends its text is read back. Neovim writes terminal output
-- to the buffer on a short timer, after the TermRequest that announced the link.
local OSC8_SETTLE_MS = 50

---Record OSC 8 hyperlinks the program in terminal `buf` prints, so the link under the
---cursor can use their target. A span remembers its text; once the program writes over
---it, the span no longer counts.
---@param buf integer
function M.attach_osc8(buf)
  local open
  local group = vim.api.nvim_create_augroup("duet.links.osc8." .. buf, { clear = true })
  osc8_spans[buf] = {}
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = buf,
    desc = "duet: forget OSC 8 hyperlinks",
    callback = function()
      osc8_spans[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  vim.api.nvim_create_autocmd("TermRequest", {
    group = group,
    buffer = buf,
    desc = "duet: record OSC 8 hyperlinks",
    callback = function(ev)
      local data = ev.data
      local seq = type(data) == "table" and data.sequence or nil
      local uri = type(seq) == "string" and seq:match("^\27%]8;[^;]*;(.*)$")
      if not uri then
        return
      end
      local cursor = data.cursor
      if uri ~= "" then
        open = cursor and { uri = uri, row = cursor[1], col = cursor[2] } or nil
        return
      end
      local start = open
      open = nil
      if not (start and cursor and start.row >= 1 and cursor[1] == start.row and cursor[2] > start.col) then
        return
      end
      local row, s, e = start.row - 1, start.col, cursor[2]
      vim.defer_fn(function()
        local spans = osc8_spans[buf]
        if not spans or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local text = slice(buf, row, s, e)
        if text == "" then
          return
        end
        -- A TUI prints the same link again on every redraw: keep one span per position.
        local old = vim.api.nvim_buf_get_extmarks(buf, osc8_ns, { row, s }, { row, s }, {})
        for _, mark in ipairs(old) do
          vim.api.nvim_buf_del_extmark(buf, osc8_ns, mark[1])
          spans[mark[1]] = nil
        end
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, osc8_ns, row, s, { end_col = e })
        if ok then
          spans[id] = { uri = start.uri, text = text }
        end
      end, OSC8_SETTLE_MS)
    end,
  })
end

return M
