---@brief Send text to the agent: type it into the agent's terminal.
--- Agent TUIs take a newline as "submit", so text goes in as one bracketed paste
--- (`ESC [200~` … `ESC [201~`) and is submitted with a carriage return after a short delay,
--- once the TUI has taken the paste in. Control characters are removed first, so text can't
--- end the paste early or type keys. Large payloads are written in chunks, one per event
--- loop turn, so the editor stays responsive. Sends to one session run in order. Each
--- send waits until the agent's TUI is ready for input (its input prompt is on screen, not
--- a dialog); if the agent isn't running it is started first.
--- See |duet-send|.

local M = {}

M.PASTE_START = "\27[200~"
M.PASTE_END = "\27[201~"
M.SUBMIT = "\r"
-- Bytes per nvim_chan_send call.
M.CHUNK_SIZE = 4096
-- How long the agent may look not ready when Enter is due before duet takes it for a
-- dialog: a redraw, e.g. after a large paste, can leave the input box off screen for a
-- while. A real dialog only makes the send fail later.
-- It is also how long the agent may take to show the paste in its input box (with an
-- adapter that has `read_input`) before duet presses Enter anyway.
M.SUBMIT_GRACE_MS = 2000
-- With an adapter that has `read_input`: how long the agent may take to show that it took
-- Enter in (its input box changes) before the next send goes on anyway.
M.SUBMIT_SETTLE_MS = 2000
-- The longest single-line text whose last word duet looks for in the input box, and how
-- much of that word (see M.probe).
M.PROBE_TEXT_MAX = 200
M.PROBE_BYTES = 16

---@class duet.SendOpts
---@field submit? boolean press Enter after the paste (default: true)
---@field focus? boolean move the cursor into the agent's terminal (default: false)
---@field agent? string agent name (default: the current session's agent, else the `agent` option)
---@field session? duet.Session send to this session instead; it must be running
---@field on_done? fun(err?: string) called once the text is written, or with an error if it could not be

---@class duet.SendItem
---@field text string sanitized text
---@field submit boolean
---@field on_done? fun(err?: string)

---Pending sends per session id, written one at a time.
---@type table<string, duet.SendItem[]>
local queues = {}

---Remove characters that could break the TUI or end the paste early: every C0 control
---character except newline and tab, DEL, and the C1 controls (U+0080 to U+009F). Line
---endings become "\n". Pure.
---@param text string
---@return string
function M.sanitize(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  -- C1 controls as UTF-8. Bytes 0x80 to 0x9F on their own are continuation bytes of other
  -- characters, so they stay.
  return (text:gsub("\194[\128-\159]", ""))
end

---Wrap text in bracketed paste markers. Pure.
---@param text string sanitized text
---@return string
function M.payload(text)
  return M.PASTE_START .. text .. M.PASTE_END
end

---Split `data` into chunks of at most `size` bytes, never inside a UTF-8 character (unless
---a single character is longer than `size`, or the data is not UTF-8). Pure.
---@param data string
---@param size integer chunk size in bytes, at least 1
---@return string[]
function M.chunks(data, size)
  vim.validate("size", size, function(v)
    return type(v) == "number" and v >= 1
  end, "positive number")
  local list = {}
  local i, n = 1, #data
  while i <= n do
    local j = math.min(i + size - 1, n)
    if j < n then
      -- Step back from the next byte to the start of its character.
      local k = j + 1
      while k > i and data:byte(k) >= 0x80 and data:byte(k) < 0xC0 do
        k = k - 1
      end
      if k > i then
        j = k - 1
      end
    end
    list[#list + 1] = data:sub(i, j)
    i = j + 1
  end
  return list
end

---The writes for one paste. A paste that fits in a chunk is one write, so nothing the
---user types can land inside it. A longer one is the start marker, the text in chunks,
---then the end marker: the markers go on their own, so a chunk boundary never splits one
---(an agent could read the ESC of a split marker as the Escape key). Pure.
---@param text string sanitized text
---@return string[]
function M.writes(text)
  local whole = M.payload(text)
  if #whole <= M.CHUNK_SIZE then
    return { whole }
  end
  local list = { M.PASTE_START }
  vim.list_extend(list, M.chunks(text, M.CHUNK_SIZE))
  list[#list + 1] = M.PASTE_END
  return list
end

---A piece of `text` that the agent's input box shows while the text is in it: its last
---word, cut to PROBE_BYTES (the last, since an agent may take a leading character as a
---mode switch, as Claude Code does with `!`). nil for text with several lines or more than
---PROBE_TEXT_MAX bytes, which an agent may show as a summary such as
---`[Pasted text #1 +20 lines]`. Pure.
---@param text string sanitized text
---@return string|nil
function M.probe(text)
  if text:find("\n") or #text > M.PROBE_TEXT_MAX then
    return nil
  end
  local word = text:match("(%S+)%s*$")
  return word and M.chunks(word, M.PROBE_BYTES)[1]
end

---@param session duet.Session
---@param data string
---@return boolean|nil ok
---@return string|nil err
local function write(session, data)
  if not session.job then
    return nil, ("send: %s exited"):format(session.agent.name)
  end
  local ok, err = pcall(vim.api.nvim_chan_send, session.job, data)
  if not ok then
    return nil, ("send: cannot write to %s: %s"):format(session.agent.name, err)
  end
  return true
end

---Report how each item ended: through its `on_done`, or a notification for items without
---one (only once, however many failed together).
---@param items duet.SendItem[]
---@param err? string
local function finish(items, err)
  local notify = false
  for _, item in ipairs(items) do
    if item.on_done then
      local ok, cb_err = pcall(item.on_done, err)
      if not ok then
        require("duet.log").error("send: on_done failed: %s", cb_err)
      end
    elseif err then
      notify = true
    end
  end
  if notify then
    require("duet.util").notify(err, vim.log.levels.ERROR)
  end
end

---Show the session if it is hidden, without moving the cursor, so the user sees what
---the agent is asking.
---@param session duet.Session
local function reveal(session)
  if session:is_visible() then
    return
  end
  local win, err = session:show()
  if not win then
    require("duet.log").warn("session %s: cannot show the terminal: %s", session.id, err)
  end
end

---Write the session's queued items one after another, until its queue is empty.
---@param session duet.Session
local function process(session)
  local queue = queues[session.id]
  local item = queue and queue[1]
  if not item then
    queues[session.id] = nil
    return
  end

  ---Finish the item and go on with the next one.
  local function done()
    table.remove(queue, 1)
    finish({ item })
    process(session)
  end

  -- Drop everything queued for the session: later text must not arrive without the
  -- text before it.
  local function fail(err)
    queues[session.id] = nil
    require("duet.log").warn("session %s: %s", session.id, err)
    finish(queue, err)
  end

  -- The agent is starting up or asking something (a dialog): let the user see it.
  local ready_now, now_err = session:is_ready()
  if not ready_now and not now_err then
    reveal(session)
  end

  session:when_ready(require("duet.config").get().send.ready_timeout_ms, function(ready_err)
    if ready_err then
      fail(ready_err)
      return
    end
    local writes = M.writes(item.text)
    require("duet.log").debug("session %s: sending %d bytes in %d writes", session.id, #item.text, #writes)
    -- With an adapter that reads the input box: what the box showed before the paste, to
    -- tell when the agent has taken the paste in, then Enter.
    local reading = session.agent.read_input ~= nil
    local probe = M.probe(item.text)
    ---The input box now, or nil. A read_input that fails turns the waits off for this
    ---item: the send goes on as for an adapter without one.
    local function input()
      if not reading then
        return nil
      end
      local box, input_err = session:input()
      if input_err then
        reading = false
        require("duet.log").warn("session %s: %s: not waiting for the input box", session.id, input_err)
      end
      return box
    end
    ---Whether `box` shows the text: it has changed since `from`, and holds the probe.
    local function holds(box, from)
      return box ~= nil and box ~= from and (not probe or box:find(probe, 1, true) ~= nil)
    end
    local before = input()
    local i = 0
    ---@param seen boolean the paste showed in the box
    local function press_enter(seen)
      local shown = input()
      local ok, err = write(session, M.SUBMIT)
      if not ok then
        fail(err)
        return
      end
      if not reading then
        done()
        return
      elseif not seen then
        -- Drawn later, the paste would pass for Enter taken in: wait the whole time.
        vim.defer_fn(done, M.SUBMIT_SETTLE_MS)
        return
      end
      -- Wait until the agent has taken Enter in: the box has changed and no longer holds
      -- the text. Until then, a paste would land in the text being submitted (Claude Code
      -- submits a slash command after a moment, more so while it starts).
      session:poll(M.SUBMIT_SETTLE_MS, function()
        local box = input()
        return not reading or (box ~= nil and box ~= shown and not (probe and box:find(probe, 1, true)))
      end, function(_, timed_out)
        if timed_out then
          require("duet.log").debug("session %s: the input did not change after Enter", session.id)
        end
        done()
      end)
    end
    local function submit()
      -- Wait until the agent shows the paste in its input: Enter before it has taken the
      -- paste in would be checked against an old screen. The agent may also have started
      -- asking something (a permission dialog) since the paste: Enter would answer it.
      -- Leave the text in its input instead, and drop the sends queued after it, which
      -- would be pasted after it and submitted with it.
      local seen = false
      session:poll(M.SUBMIT_GRACE_MS, function()
        local ready, check_err = session:is_ready()
        if not ready then
          return ready, check_err
        end
        local box = input()
        seen = reading and holds(box, before)
        return seen or not reading
      end, function(poll_err, timed_out)
        if poll_err then
          fail(poll_err)
          return
        elseif timed_out then
          local ready, check_err = session:is_ready()
          if check_err then
            fail(check_err)
            return
          elseif not ready then
            reveal(session)
            fail(("send: %s is asking something: the text was pasted but not submitted"):format(session.agent.name))
            return
          end
          -- Ready, but the paste never showed: press Enter anyway, as for an agent
          -- whose input duet can't read.
          require("duet.log").debug("session %s: the paste did not show in the input", session.id)
        end
        press_enter(seen)
      end)
    end
    local function write_next()
      i = i + 1
      if i > #writes then
        if item.submit then
          vim.defer_fn(submit, require("duet.config").get().send.submit_delay_ms)
        else
          done()
        end
        return
      end
      local ok, err = write(session, writes[i])
      if not ok then
        fail(err)
        return
      end
      vim.schedule(write_next)
    end
    write_next()
  end)
end

---Send text to the agent as one paste, and submit it. Returns once the text is queued;
---`opts.on_done` tells when it has been written. Starts the agent if it isn't running
---(showing its terminal, without moving the cursor). Each send waits until the agent's
---TUI is ready for input, so text never goes into a dialog; a hidden agent that is
---asking something is shown. If a dialog opens between the paste and Enter, the text is
---left pasted but not submitted, and the sends queued after it are dropped.
---Errors found at once are returned and `on_done` is not called. Later errors go to
---`on_done`, or are shown to the user if there is none. `on_done` is always called after
---send() has returned. See |duet.send()|.
---@param text string
---@param opts? duet.SendOpts
---@return boolean|nil ok
---@return string|nil err
function M.send(text, opts)
  vim.validate("text", text, "string")
  vim.validate("opts", opts, "table", true)
  opts = opts or {}
  local clean = M.sanitize(text)
  if vim.trim(clean) == "" then
    return nil, "send: nothing to send"
  end

  local session, err = opts.session, nil
  if session then
    if not session:is_running() then
      return nil, ("send: %s is not running"):format(session.agent.name)
    end
  else
    session, err = require("duet.terminal").ensure(opts.agent, { show = true })
    if not session then
      return nil, err
    end
  end
  if opts.focus then
    local win, focus_err = session:focus()
    if not win then
      return nil, focus_err
    end
  end

  local queue = queues[session.id]
  local idle = queue == nil
  if idle then
    queue = {}
    queues[session.id] = queue
  end
  queue[#queue + 1] = { text = clean, submit = opts.submit ~= false, on_done = opts.on_done }
  if idle then
    -- On the next loop turn, so on_done never runs before send() returns.
    vim.schedule(function()
      process(session)
    end)
  end
  return true
end

-- Command handlers ------------------------------------------------------------

---Expand `{name}` placeholders in `text` with `ctx`, then send it.
---@param text string
---@param ctx duet.Context
---@param submit boolean
---@return boolean|nil
---@return string|nil err
local function expand_and_send(text, ctx, submit)
  local expanded, err, warning = require("duet.context").expand(text, ctx)
  if not expanded then
    return nil, "send: " .. err
  end
  if warning then
    require("duet.util").notify("send: " .. warning, vim.log.levels.WARN)
  end
  return M.send(expanded, { submit = submit })
end

---`:[range]Duet[!] send <text>`: expand the placeholders in the text (see
---|duet-context|), send it and submit it, or only paste it with `!`.
---@param args string[]
---@param opts? duet.CommandOpts
---@return boolean|nil
---@return string|nil err
function M.cmd_send(args, opts)
  opts = opts or {}
  local text = opts.rest or table.concat(args, " ")
  if vim.trim(text) == "" then
    return nil, "send: usage: :Duet send <text>"
  end
  local context = require("duet.context")
  local ctx = context.capture(opts)
  context.leave_visual()
  return expand_and_send(text, ctx, not opts.bang)
end

---`:[range]Duet[!] prompt [text]`: ask for text with vim.ui.input (prefilled with
---`text`), expand its placeholders and send it, or only paste it with `!`. The context
---is captured before the input opens. Cancelling sends nothing.
---@param args string[]
---@param opts? duet.CommandOpts
---@return boolean
function M.cmd_prompt(args, opts)
  opts = opts or {}
  local default = opts.rest or table.concat(args, " ")
  local context = require("duet.context")
  local ctx = context.capture(opts)
  context.leave_visual()
  vim.ui.input({ prompt = "duet> ", default = default }, function(input)
    if input == nil or vim.trim(input) == "" then
      return
    end
    local ok, err = expand_and_send(input, ctx, not opts.bang)
    if not ok then
      require("duet.util").notify(err, vim.log.levels.ERROR)
    end
  end)
  return true
end

return M
