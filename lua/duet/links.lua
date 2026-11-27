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
---@field tail? { row: integer, s: integer, e: integer } the part of a reference wrapped
---onto the next row; `s` and `e` then end the part on `row`

local FLASH_MS = 300
local NO_LINK = "links: no file link under the cursor"

local hl_ns = vim.api.nvim_create_namespace("duet.links")
local flash_ns = vim.api.nvim_create_namespace("duet.links.flash")
local osc8_ns = vim.api.nvim_create_namespace("duet.links.osc8")

---@class duet.links.Span an OSC 8 hyperlink the program printed
---@field uri string its target
---@field s_cell integer 0-based screen cell where it starts
---@field e_cell integer screen cell where it ends (exclusive)
---@field text? string its text, once it is in the buffer; the span counts while it stays
---@field line? string the text of its line when the terminal first wrote it, until settled
---@field early? string the text of its line when TermRequest came, until settled

---@class duet.links.Spans
---@field by_id table<integer, duet.links.Span> by extmark id
---@field order integer[] extmark ids, oldest first; may hold ids already dropped
---@field count integer spans in `by_id`
---@field pending table<integer, true> ids of spans whose line the terminal has not written yet

---OSC 8 spans by buffer.
---@type table<integer, duet.links.Spans>
local osc8_spans = {}
local drop_span

-- At most this many OSC 8 spans are kept per terminal: the oldest go first.
local MAX_OSC8_SPANS = 500

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

-- Locations followed by more text, as grep and ripgrep print matches: `a.lua:12:text`,
-- `a.lua:12:5:text`. Tried when no suffix matches the whole token.
local PREFIXES = { "^(.-):(%d+):(%d+):()", "^(.-):(%d+):()" }

---Split a reference like `a.lua:10-20` into its path and location.
---@param token string
---@return string path
---@return integer|nil line
---@return integer|nil end_line
---@return integer|nil col
---@return integer used bytes of `token` the reference takes, up to its location
local function split_location(token)
  for _, try in ipairs(SUFFIXES) do
    local p, l, e, c = try(token)
    if p and p ~= "" then
      return p, tonumber(l), tonumber(e), tonumber(c), #token
    end
  end
  for _, pattern in ipairs(PREFIXES) do
    local p, l, c, after = token:match(pattern)
    if after == nil then
      c, after = nil, c
    end
    if p and p ~= "" then
      -- The reference ends before the colon that starts the text.
      return p, tonumber(l), nil, tonumber(c), after - 2
    end
  end
  return token, nil, nil, nil, #token
end

---The path of a `file://` URI, still percent-encoded, or nil if `token` is not one.
---Decode it after splitting off the location: a `%23` is part of the name, not a `#`.
---@param token string
---@return string|nil
local function file_uri_path(token)
  return token:match("^file://[^/]*(/.*)$")
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
---@return integer|nil used bytes of `token` the reference takes: less than all of it for
---grep output such as `a.lua:12:text`
function M.parse_ref(token, marked)
  local length = #token
  local uri_path = file_uri_path(token)
  if uri_path then
    token = uri_path
    marked = true
  end
  local path, line, end_line, col, used = split_location(token)
  if uri_path then
    path, used = vim.uri_decode(path), length
  elseif path:find("://", 1, true) then
    return nil -- a URL
  end
  if not plausible(path, marked == true, line ~= nil) then
    return nil
  end
  if end_line and line and end_line < line then
    line, end_line = end_line, line
  end
  if end_line == line then
    end_line = nil
  end
  return { path = path, line = line, end_line = end_line, col = col }, used
end

---A grep or ripgrep context line, `a.lua-12-text`: the path before the first `-N-` that
---looks like a file and exists. Hyphens are common in names (`my-file-12-notes.md`), so
---this is only tried when the whole token is not a file, and a bare name without an
---extension or `/` does not count.
---@param token string
---@param exists fun(path: string): boolean
---@return { path: string, line: integer }|nil
---@return integer|nil used bytes of `token` the reference takes, up to its line number
local function context_ref(token, exists)
  local init = 1
  while true do
    local s, e, num = token:find("%-(%d+)%-", init)
    if not s then
      return nil
    end
    local path = token:sub(1, s - 1)
    if path ~= "" and not path:find("://", 1, true) and plausible(path, false, false) and exists(path) then
      return { path = path, line = tonumber(num) }, e - 1
    end
    init = s + 1
  end
end

---@class duet.links.ParseOpts
---@field exists? fun(path: string): boolean whether a path is a file; with it, grep
---context lines (`a.lua-12-text`) are recognized too

---Find the file references in a line of text, e.g. `lua/duet/init.lua:10`,
---`a.go:12:3`, `a.lua:L10-L20`, `a.lua#L10`, `@a.lua (lines 3-5)`, `` `Makefile` ``,
---`File "a.py", line 10` or `file:///abs/a.lua#L3`. URLs are skipped. Candidates are not
---checked against the filesystem (see resolve()), except through `opts.exists`.
---@param line string
---@param opts? duet.links.ParseOpts
---@return duet.Link[] links in order of appearance
function M.parse(line, opts)
  local exists = opts and opts.exists
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
      local ref, used
      if trimmed ~= "" then
        ref, used = M.parse_ref(trimmed, at or backticked)
        if exists and not (ref and exists(ref.path)) then
          local context, context_used = context_ref(trimmed, exists)
          if context then
            ref, used = context, context_used
          end
        end
      end
      if ref and used and used < #trimmed then
        te = ts + used - 1 -- `a.lua:12:text`: the text after the location is not part of it
      end
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
          if l2 and l2 < l1 then
            l1, l2 = l2, l1
          end
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
          s = at and (s + lead:find("@", 1, true) - 1) or ts,
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
  return M.resolver(cwd)(path)
end

---A resolve() for many paths from one `cwd`: the git root is looked up once, when the
---first path needs it.
---@param cwd? string default: the current working directory
---@return fun(path: string): string|nil, string|nil
function M.resolver(cwd)
  local base, root
  return function(path)
    local expanded = path
    if path == "~" or vim.startswith(path, "~/") then
      expanded = vim.fs.normalize(path)
    end
    local candidates = {}
    if vim.startswith(expanded, "/") then
      candidates[1] = expanded
    else
      if not base then
        base = vim.fs.normalize(vim.fs.abspath(cwd or vim.uv.cwd() or "."))
        root = require("duet.util").git_root(base) or false
      end
      candidates[1] = vim.fs.joinpath(base, expanded)
      if root and root ~= base then
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

-- A row this many cells short of the terminal's width still counts as full when the TUI
-- wrapped it: Claude Code breaks its prompt one cell early.
local WRAP_SLACK = 1

---@class duet.links.FindOpts
---@field resolve fun(path: string): string|nil the absolute path a link's path refers to
---@field is_file? fun(abs: string): boolean whether a resolved path is a regular file, for
---grep context lines (default: asks the filesystem)
---@field first? integer buffer row of `lines[1]` (default 1)
---@field width? integer the terminal's width in cells; without it, no lines are joined

---@param abs string
---@return boolean
local function is_file(abs)
  local stat = vim.uv.fs_stat(abs)
  return stat ~= nil and stat.type == "file"
end

---Whether row `head`, without its trailing spaces, may go on in the next row: it fills
---the terminal's width, but is not wider (rows from before the terminal was narrowed).
---@param head string
---@param width? integer
---@return boolean
local function may_wrap(head, width)
  if not width or head == "" then
    return false
  end
  local cells = vim.fn.strdisplaywidth(head)
  return cells <= width and cells >= width - WRAP_SLACK
end

---Whether `token`, the joined text of a reference across a full row `head` and the next
---row, was one word wrapped rather than two. With no indent, the terminal wrapped the
---line, which it does mid-text, so the row must fill the width: one cell short only when
---the next row starts with a wide character, which did not fit in the last cell. A row
---that fills the width and then ends is indistinguishable from it. An indent means a TUI
---wrapped it: that breaks at a space unless the word is too wide for a row, so the
---reference must be.
---@param head string
---@param indent string
---@param rest string the next row after its indent
---@param token string
---@param width integer
---@return boolean
local function one_word(head, indent, rest, token, width)
  if indent == " " then
    return false -- text the terminal wrapped, not an indent: TUIs indent by two or more
  end
  if indent == "" then
    local cells = vim.fn.strdisplaywidth(head)
    return cells == width or (cells == width - 1 and vim.fn.strdisplaywidth(vim.fn.strcharpart(rest, 0, 1)) == 2)
  end
  return vim.fn.strdisplaywidth(token) > width - vim.fn.strdisplaywidth(indent)
end

---The links in `lines` (buffer rows from `opts.first`) that resolve, with `row` and `abs`,
---in order. A reference wrapped at the terminal's width (libvterm wraps long lines, and a
---TUI such as Claude Code wraps its text and indents what follows) is found by joining a
---full row with the next one, without its indent. Joined, it counts only if it resolves;
---its part on the next row is in `tail`.
---@param lines string[]
---@param opts duet.links.FindOpts
---@return duet.Link[]
function M.find(lines, opts)
  local first = opts.first or 1
  local cache = {}
  local function resolve(path)
    if cache[path] == nil then
      cache[path] = opts.resolve(path) or false
    end
    return cache[path] or nil
  end
  local files = {}
  local parse_opts = {
    exists = function(path)
      local abs = resolve(path)
      if abs and files[abs] == nil then
        files[abs] = (opts.is_file or is_file)(abs)
      end
      return abs ~= nil and files[abs]
    end,
  }
  ---@type duet.Link[][]
  local rows = {}
  for i, text in ipairs(lines) do
    rows[i] = {}
    for _, link in ipairs(M.parse(text, parse_opts)) do
      link.abs = resolve(link.path)
      if link.abs then
        link.row = first + i - 1
        table.insert(rows[i], link)
      end
    end
  end
  -- A TUI pads the rows it draws with spaces, which the terminal keeps in the buffer.
  local trimmed = vim.tbl_map(function(text)
    return (text:gsub("%s+$", ""))
  end, lines)
  for i = 1, #lines - 1 do
    local head = trimmed[i]
    local indent, rest = trimmed[i + 1]:match("^(%s*)(.*)$")
    if rest ~= "" and may_wrap(head, opts.width) then
      local joined = head .. rest
      for _, link in ipairs(M.parse(joined, parse_opts)) do
        local abs = link.s <= #head
          and link.e > #head
          and one_word(head, indent, rest, joined:sub(link.s, link.e), opts.width)
          and resolve(link.path)
        local tail_e = link.e - #head + #indent
        -- A tail that fills its row too may go on in a third row: not recognized.
        local cut = tail_e == #trimmed[i + 1] and lines[i + 2] ~= nil and may_wrap(trimmed[i + 1], opts.width)
        if abs and not cut then
          -- The parts on each row, found on their own, are replaced by the whole.
          rows[i] = vim.tbl_filter(function(other)
            return other.e < link.s
          end, rows[i])
          rows[i + 1] = vim.tbl_filter(function(other)
            return other.s > tail_e
          end, rows[i + 1])
          link.row, link.e, link.abs = first + i - 1, #head, abs
          link.tail = { row = first + i, s = #indent + 1, e = tail_e }
          table.insert(rows[i], link)
        end
      end
    end
  end
  local found = {}
  for _, row in ipairs(rows) do
    vim.list_extend(found, row)
  end
  return found
end

---Whether a (1-based row, 1-based byte col) position is on a link, or its wrapped tail.
---@param link duet.Link
---@param row integer
---@param col integer
---@return boolean
local function contains(link, row, col)
  local tail = link.tail
  return (link.row == row and link.s <= col and col <= link.e)
    or (tail ~= nil and tail.row == row and tail.s <= col and col <= tail.e)
end

---The width of the terminal in `buf`: Neovim sizes it to the widest window showing it.
---Nil for other buffers, whose lines do not wrap.
---@param buf integer
---@return integer|nil
local function term_width(buf)
  if vim.bo[buf].buftype ~= "terminal" then
    return nil
  end
  local width
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local cells = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
    width = math.max(width or 0, cells)
  end
  return width
end

---Links that resolve in rows `first` to `last` of `buf`, including those that wrap into
---the range from the row above or out of it into the row below.
---@param buf integer
---@param first integer
---@param last integer
---@param cwd string
---@return duet.Link[]
local function resolved_links(buf, first, last, cwd)
  local from = math.max(first - 1, 1)
  local to = math.min(last + 1, vim.api.nvim_buf_line_count(buf))
  local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
  local links = M.find(lines, { first = from, width = term_width(buf), resolve = M.resolver(cwd) })
  return vim.tbl_filter(function(link)
    local tail = link.tail
    return (link.row >= first and link.row <= last) or (tail ~= nil and tail.row >= first and tail.row <= last)
  end, links)
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

---The byte offset in `text` of a 0-based screen cell, as a terminal counts them: a wide
---character takes two cells. Past the end of `text`, its length.
---@param text string
---@param cell integer
---@return integer
function M.cell_to_byte(text, cell)
  local byte, cells = 0, 0
  while cells < cell and byte < #text do
    local len = vim.str_utf_end(text, byte + 1) + 1
    cells = cells + vim.fn.strdisplaywidth(text:sub(byte + 1, byte + len))
    byte = byte + len
  end
  return byte
end

---Forget an OSC 8 span and its extmark.
---@param buf integer
---@param id integer
drop_span = function(buf, id)
  local store = osc8_spans[buf]
  if store and store.by_id[id] then
    store.by_id[id] = nil
    store.pending[id] = nil
    store.count = store.count - 1
  end
  pcall(vim.api.nvim_buf_del_extmark, buf, osc8_ns, id)
end

---Record a span under its extmark, dropping the oldest ones past MAX_OSC8_SPANS.
---@param buf integer
---@param id integer
---@param span duet.links.Span
local function add_span(buf, id, span)
  local store = osc8_spans[buf]
  store.by_id[id] = span
  store.count = store.count + 1
  store.order[#store.order + 1] = id
  if #store.order > 2 * MAX_OSC8_SPANS then
    store.order = vim.tbl_filter(function(old)
      return store.by_id[old] ~= nil
    end, store.order)
  end
  while store.count > MAX_OSC8_SPANS do
    drop_span(buf, table.remove(store.order, 1))
  end
end

---Turn a span into a ranged extmark over its text, from `span.line`: the line as the
---terminal first wrote it after the link, before anything could write over it. The extmark
---has stayed on the span's line, wherever trimming the scrollback moved it, and the text's
---byte columns follow from the screen cells.
---@param buf integer
---@param id integer
local function settle_span(buf, id)
  local store = osc8_spans[buf]
  local span = store and store.by_id[id]
  if not span or not span.line or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, osc8_ns, id, {})
  if #pos == 0 then
    drop_span(buf, id)
    return
  end
  local row, line = pos[1], span.line
  span.line = nil
  local s, e = M.cell_to_byte(line, span.s_cell), M.cell_to_byte(line, span.e_cell)
  -- Blank cells: the frame with the link was replaced before it was shown.
  if e <= s or not line:sub(s + 1, e):find("%S") then
    drop_span(buf, id)
    return
  end
  -- A TUI prints the same link again on every redraw: keep one span per position.
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, osc8_ns, { row, s }, { row, s }, {})) do
    local other = store.by_id[mark[1]]
    if mark[1] ~= id and other and other.text then
      drop_span(buf, mark[1])
    end
  end
  vim.api.nvim_buf_set_extmark(buf, osc8_ns, row, s, { id = id, end_col = e })
  span.text = line:sub(s + 1, e)
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
  local store = osc8_spans[buf]
  if not store then
    return nil
  end
  for _, mark in ipairs(marks) do
    local id, r, s, details = mark[1], mark[2], mark[3], mark[4]
    local span = store.by_id[id]
    local e = details.end_col
    local inside = span and span.text and e and s < col and col <= e
    -- Output rewritten over the span makes it stale: its text must still be there.
    if inside and slice(buf, r, s, e) ~= span.text then
      drop_span(buf, id)
      inside = false
    end
    if inside then
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

---The link at a position in `win`, resolved. An OSC 8 hyperlink there comes first.
---@param win integer
---@param row integer 1-based buffer row
---@param col integer 1-based byte column
---@return duet.Link|nil link
---@return string|nil err a link that does not resolve, or no link at all
function M.at(win, row, col)
  local buf = vim.api.nvim_win_get_buf(win)
  local cwd = M.cwd(buf)
  local osc8 = osc8_at(buf, row, col, cwd)
  if osc8 then
    return osc8
  end
  for _, link in ipairs(resolved_links(buf, row, row, cwd)) do
    if contains(link, row, col) then
      return link
    end
  end
  -- Say why a reference under the cursor is not a link. Parsed as find() does, the text
  -- of a grep context line is not part of its reference.
  local resolve = M.resolver(cwd)
  local exists = function(path)
    local abs = resolve(path)
    return abs ~= nil and is_file(abs)
  end
  for _, link in ipairs(M.parse(get_line(buf, row), { exists = exists })) do
    if link.s <= col and col <= link.e then
      local _, err = resolve(link.path)
      return nil, err or NO_LINK
    end
  end
  return nil, NO_LINK
end

---The link under the cursor in `win`, resolved. An OSC 8 hyperlink there comes first.
---@param win? integer default: the current window
---@return duet.Link|nil link
---@return string|nil err a link that does not resolve, or no link at all
function M.at_cursor(win)
  win = win or vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  return M.at(win, cursor[1], cursor[2] + 1)
end

---The link under the mouse, from |getmousepos()| in a mapping for a click, resolved. Only
---text in a duet terminal counts.
---@return duet.Link|nil link
---@return integer|nil win the window clicked, when the click was on a duet terminal's text
function M.at_mouse()
  local pos = vim.fn.getmousepos()
  local win = pos.winid
  if win == 0 or pos.line == 0 or not vim.api.nvim_win_is_valid(win) then
    return nil, nil -- the command line, a status line or a separator
  end
  if vim.b[vim.api.nvim_win_get_buf(win)].duet_session == nil then
    return nil, nil
  end
  return (M.at(win, pos.line, pos.column)), win
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
  return resolved_links(buf, first, last, M.cwd(buf))
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

---@class duet.links.Undo what target_window() changed, for when the file does not open
---@field win integer the window that was current
---@field created? integer the split it opened
---@field hidden? duet.Session the floating terminal it hid
---@field buf? integer the empty buffer the split opened with; a failed `:edit` may
---have named it
---@field replaced? duet.links.Replaced the start screen the file was to replace

---@class duet.links.Replaced
---@field win integer its window
---@field buf integer its buffer, which is often wiped when the window leaves it
---@field bufs table<integer, true> the buffers that existed before, so the one a failed
---`:edit` created can be told apart

---Whether a file may be opened in `win` in place of what it shows: a start screen (a
---filetype in `links.replace_filetypes`) that is not modified, in a window that is not
---floating, not a terminal and does not fix its buffer.
---@param win integer
---@param filetypes string[]
---@return boolean
local function is_replaceable(win, filetypes)
  if win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_win_get_config(win).relative == ""
    and vim.b[buf].duet_session == nil
    and vim.bo[buf].buftype ~= "terminal"
    and not vim.wo[win].winfixbuf
    and not vim.bo[buf].modified
    and vim.tbl_contains(filetypes, vim.bo[buf].filetype)
end

---A start screen window in the tab to open a file in: the current window when it is
---one, else the previous window, else the widest (then the tallest). See
---is_replaceable().
---@return integer|nil win
local function replaceable_window()
  local filetypes = require("duet.config").get().links.replace_filetypes
  if #filetypes == 0 then
    return nil
  end
  local candidates = { vim.api.nvim_get_current_win() }
  local prev = vim.fn.winnr("#")
  if prev ~= 0 then
    table.insert(candidates, vim.fn.win_getid(prev))
  end
  for _, win in ipairs(candidates) do
    if is_replaceable(win, filetypes) then
      return win
    end
  end
  local best, best_size
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_replaceable(win, filetypes) then
      local size = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
      if not best or size[1] > best_size[1] or (size[1] == best_size[1] and size[2] > best_size[2]) then
        best, best_size = win, size
      end
    end
  end
  return best
end

---The window to open a file in: a code window in the tab, else a start screen window,
---else a new split. A floating duet terminal in front is hidden first, so the file is
---not opened under it.
---@return integer|nil win
---@return duet.links.Undo undo
---@return string|nil err the floating terminal could not be hidden
local function target_window()
  local util = require("duet.util")
  local cur = vim.api.nvim_get_current_win()
  local undo = { win = cur }
  local id = vim.b.duet_session
  if id and vim.api.nvim_win_get_config(cur).relative ~= "" then
    local session = require("duet.terminal").get(id)
    if session then
      local ok, err = session:hide()
      if not ok then
        return nil, undo, err
      end
      undo.hidden = session
      cur = vim.api.nvim_get_current_win()
    end
  end
  local win, found = util.code_window()
  if found then
    return win, undo
  end
  local start_screen = replaceable_window()
  if start_screen then
    local bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      bufs[b] = true
    end
    undo.replaced = { win = start_screen, buf = vim.api.nvim_win_get_buf(start_screen), bufs = bufs }
    return start_screen, undo
  end
  vim.cmd(SPLIT_FROM[vim.w[cur].duet_layout] or "leftabove vnew")
  undo.created = vim.api.nvim_get_current_win()
  undo.buf = vim.api.nvim_get_current_buf()
  return undo.created, undo
end

---Put the layout back as it was before target_window().
---@param undo duet.links.Undo
local function restore_layout(undo)
  if undo.created and vim.api.nvim_win_is_valid(undo.created) then
    pcall(vim.api.nvim_win_close, undo.created, true)
  end
  local buf = undo.buf
  if buf and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  local replaced = undo.replaced
  if replaced and vim.api.nvim_win_is_valid(replaced.win) then
    local shown = vim.api.nvim_win_get_buf(replaced.win)
    if shown ~= replaced.buf then
      -- The start screen comes back if it is still loaded. Most are wiped when left:
      -- the window then gets an empty buffer, as after the start screen's own `:enew`.
      if vim.api.nvim_buf_is_loaded(replaced.buf) then
        pcall(vim.api.nvim_win_set_buf, replaced.win, replaced.buf)
      else
        pcall(vim.api.nvim_win_call, replaced.win, vim.cmd.enew)
      end
      -- The buffer the failed `:edit` created goes; one the user had already stays.
      if
        not replaced.bufs[shown]
        and vim.api.nvim_buf_is_valid(shown)
        and not vim.bo[shown].modified
        and #vim.fn.win_findbuf(shown) == 0
      then
        pcall(vim.api.nvim_buf_delete, shown, { force = true })
      end
    end
  end
  if undo.hidden then
    local win = undo.hidden:show()
    if win then
      vim.api.nvim_set_current_win(win)
    end
  elseif vim.api.nvim_win_is_valid(undo.win) then
    vim.api.nvim_set_current_win(undo.win)
  end
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
  local win, undo, hide_err = target_window()
  if not win then
    return nil, ("links: cannot open '%s': %s"):format(link.path, hide_err)
  end
  vim.api.nvim_set_current_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) ~= abs then
    vim.cmd("normal! m'")
    local ok, edit_err = pcall(vim.cmd.edit, vim.fn.fnameescape(abs))
    if not ok then
      restore_layout(undo)
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
---@param opts? { fallback?: string } with no reference under the cursor, run these keys'
---built-in action (as with `:normal!`) instead of saying so
function M.follow(opts)
  local link, err = M.at_cursor()
  if link then
    link, err = M.open(link)
  elseif err == NO_LINK and opts and opts.fallback then
    vim.cmd.normal({ args = { vim.v.count1 .. vim.keycode(opts.fallback) }, bang = true })
    return
  end
  if not link then
    require("duet.util").notify(err or "links: nothing to open", vim.log.levels.WARN)
  end
end

-- Whether click() kept the last press for itself, leaving the focus in the terminal: its
-- drag and release are then kept too (see click_rest()).
local swallowing = false

---The drag and release keys that go with a press `lhs`, such as `<C-LeftDrag>` and
---`<C-LeftRelease>` for `<C-LeftMouse>`. Nil for a key that is not a mouse button press.
---@param lhs string
---@return { drag: string, release: string }|nil
function M.click_keys(lhs)
  local mods, button = vim.fn.keytrans(vim.keycode(lhs)):match("^<(.-)(%u%l+)Mouse>$")
  if not mods then
    return nil
  end
  mods = mods:gsub("%d%-", "") -- a double-click's drag and release have no count
  return {
    drag = ("<%s%sDrag>"):format(mods, button),
    release = ("<%s%sRelease>"):format(mods, button),
  }
end

---The drag or release of a click (mapped next to the `"open_link_mouse"` key): kept when
---click() kept the press, so the agent gets no release without its press and a drag
---does not leave Terminal mode; else passed on.
---@param key string the drag or release key
---@param release boolean whether it is the release, which ends the click
function M.click_rest(key, release)
  if swallowing then
    swallowing = not release
    return
  end
  vim.api.nvim_feedkeys(vim.keycode(key), "ni", false)
end

---Open the link under the mouse (the `"open_link_mouse"` key action, mapped to a click
---in Terminal and Normal mode). A click on a duet terminal's text that is not a link does
---nothing. A click anywhere else, such as another window or a status line, gets Neovim's
---built-in action for `lhs`.
---@param lhs string the key the action is mapped to, e.g. `"<C-LeftMouse>"`
function M.click(lhs)
  local link, win = M.at_mouse()
  swallowing = false
  if not win then
    -- Ahead of the release or drag that may already be waiting.
    vim.api.nvim_feedkeys(vim.keycode(lhs), "ni", false)
    return
  end
  if not link then
    swallowing = true
    return
  end
  local from, terminal_mode = vim.api.nvim_get_current_win(), vim.api.nvim_get_mode().mode == "t"
  if win ~= from then
    vim.api.nvim_set_current_win(win)
  end
  local ok, err = M.open(link)
  if not ok then
    -- open() restored the clicked window; go back to where the click came from.
    if vim.api.nvim_win_is_valid(from) and vim.api.nvim_get_current_win() ~= from then
      vim.api.nvim_set_current_win(from)
    end
    if terminal_mode and vim.bo.buftype == "terminal" then
      vim.cmd.startinsert()
    end
    swallowing = vim.b.duet_session ~= nil
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
  local top = visible_rows(win)
  -- Where the cursor goes on each link: its start, or the part on the next row when the
  -- start is above the window.
  local stops = vim.tbl_map(function(link)
    local part = (link.row < top and link.tail) or link
    return { row = part.row, s = part.s, e = part.e, link = link }
  end, M.visible(win))
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row, col = cursor[1], cursor[2] + 1
  local target
  for _ = 1, count do
    local step
    if dir > 0 then
      for _, stop in ipairs(stops) do
        if stop.row > row or (stop.row == row and stop.s > col) then
          step = stop
          break
        end
      end
    else
      for i = #stops, 1, -1 do
        local stop = stops[i]
        -- A link the cursor is inside is not the previous one.
        if (stop.row < row or (stop.row == row and stop.e < col)) and not contains(stop.link, row, col) then
          step = stop
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
      for _, part in ipairs({ link, link.tail }) do
        pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, part.row - 1, part.s - 1, {
          end_col = part.e,
          hl_group = "DuetLink",
        })
      end
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
    -- Throttle rather than debounce: output that never stops (a spinner) still gets its
    -- links underlined, at most once per debounce_ms.
    if timer:is_active() then
      return
    end
    local delay = require("duet.config").get().links.debounce_ms
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

-- Health ---------------------------------------------------------------------

---Report on opening links with a mouse click (for |duet-health|): the keys bound to
---`"open_link_mouse"`, and whether 'mouse' lets the click reach Neovim: Terminal and
---Normal mode get clicks with its `n` flag (or `a`).
function M.health()
  local keys = {}
  for lhs, action in pairs(require("duet.config").get().terminal.keys) do
    if action == "open_link_mouse" then
      keys[#keys + 1] = lhs
    end
  end
  if #keys == 0 then
    vim.health.info("no key in terminal.keys opens a link with a mouse click")
    return
  end
  table.sort(keys)
  local names = table.concat(keys, ", ")
  for _, lhs in ipairs(keys) do
    if not M.click_keys(lhs) then
      vim.health.warn(("%s opens the link under the mouse but is not a mouse click"):format(lhs), {
        "Bind `open_link_mouse` to a mouse key such as `<C-LeftMouse>`: in Terminal mode this key no longer reaches the agent",
      })
    end
  end
  local mouse = vim.o.mouse
  if not mouse:find("[an]") then
    vim.health.warn(
      ("'mouse' is %q, so the terminal gets no mouse clicks and %s cannot open links"):format(mouse, names),
      { "Enable the mouse in Normal mode, e.g. `vim.o.mouse = 'nvi'` (the default) or 'a'" }
    )
  else
    vim.health.ok(("%s opens links ('mouse' is %q)"):format(names, vim.o.mouse))
  end
end

-- OSC 8 ----------------------------------------------------------------------

-- How long to wait for the terminal to write a link's line after TermRequest. Neovim
-- writes terminal output to the buffer on a 10 ms timer, usually after TermRequest; with
-- longer output, sometimes before it, and then no write follows.
local OSC8_WRITE_WAIT_MS = 30

---Take the text of the lines the terminal just wrote for the spans waiting for it. This is
---the first write after the link, so the text is the link's: a later one may have written
---over it. Runs in on_lines, where the buffer can only be read; the rest is scheduled.
---@param buf integer
---@param first integer first line written (0-based)
---@param last integer line after the last one written
local function capture_lines(buf, first, last)
  local store = osc8_spans[buf]
  if not store or next(store.pending) == nil then
    return
  end
  for id in pairs(store.pending) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, osc8_ns, id, {})
    local row = pos[1]
    if row and row >= first and row < last then
      store.pending[id] = nil
      store.by_id[id].early = nil
      store.by_id[id].line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      vim.schedule(function()
        settle_span(buf, id)
      end)
    end
  end
end

---Record OSC 8 hyperlinks the program in terminal `buf` prints, so the link under the
---cursor can use their target. TermRequest gives screen cells on a row whose text is not
---in the buffer yet, so an extmark marks the row at once (it moves with the line when the
---scrollback is trimmed), and the text and its byte columns are taken when the terminal
---next writes that line. A span remembers its text; once the program writes over it, the
---span no longer counts.
---@param buf integer
function M.attach_osc8(buf)
  local open
  local group = vim.api.nvim_create_augroup("duet.links.osc8." .. buf, { clear = true })
  osc8_spans[buf] = { by_id = {}, order = {}, count = 0, pending = {} }
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, _, last_new)
      if not osc8_spans[buf] then
        return true -- detach
      end
      capture_lines(buf, first, last_new)
    end,
  })
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
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, osc8_ns, start.row - 1, 0, {})
      if not ok then
        return
      end
      local span = { uri = start.uri, s_cell = start.col, e_cell = cursor[2] }
      add_span(buf, id, span)
      -- The text is taken from the next write of the line (capture_lines). The line as it
      -- is now may still hold the previous frame of a TUI such as Claude Code, so it only
      -- counts when no write comes: Neovim wrote the line before delivering TermRequest.
      -- Blank cells then drop the span (settle_span).
      span.early = vim.api.nvim_buf_get_lines(buf, start.row - 1, start.row, false)[1] or ""
      osc8_spans[buf].pending[id] = true
      vim.defer_fn(function()
        local store = osc8_spans[buf]
        if store and store.pending[id] then
          store.pending[id] = nil
          span.line, span.early = span.early, nil
          settle_span(buf, id)
        end
      end, OSC8_WRITE_WAIT_MS)
    end,
  })
end

return M
