# AGENTS.md

Guidance for AI agents (and humans) working on **duet.nvim**. Read this before you start an issue.
The full design and roadmap live in [issue #1](https://github.com/ksysoev/duet.nvim/issues/1). Each work item is a
GitHub issue with scope, interfaces, acceptance criteria and dependencies.

## What duet is

A Neovim plugin for pairing with AI coding agents. It combines three things:

1. **Agent terminal + context** (like [sidekick.nvim](https://github.com/folke/sidekick.nvim)): run the agent CLI in a
   Neovim terminal and send it the current file, selection, diagnostics or prompt templates.
2. **Agent → editor channel**: the agent can open files, show documents in buffers, and read editor context, through an
   MCP server that duet provides.
3. **Review loop** (like [revdiff](https://github.com/umputun/revdiff)): a diff/document review UI with line
   annotations. The output uses the revdiff annotation format. A review is started by the user (results are sent as a
   prompt) or by the agent (a blocking tool call that returns the annotations). Plan review hooks into the agent's plan
   mode.

**duet is agent-agnostic.** Claude Code is the first adapter; others follow. Never let agent-specific knowledge leak
into core modules.

## Status

Early development. Work through the issues in milestone order (M0 → M5). Before you start an issue, check that its
dependencies are merged. If the code disagrees with this file or #1, the merged code wins. Update this file in the same
PR when you change architecture or conventions.

## Architecture

```
┌──────────────────────── Neovim (parent) ────────────────────────┐
│ terminal  send  context  links  show  review/*  plan            │
│      │ chansend (bracketed paste)                               │
│      ▼                                                          │
│  [agent TUI]            broker: pending requests by id          │
│      │                     ▲   (resolved when the user acts)    │
│      │                     │ msgpack-RPC over $NVIM socket      │
└──────┼─────────────────────┼────────────────────────────────────┘
       │ stdio MCP           │                    hook (stdin JSON)
       ▼                     │                          │
  nvim -l bridge/mcp.lua ────┘     nvim -l bridge/hook.lua ◄── agent hooks
```

- **Editor → agent**: text is written to the agent's terminal job with bracketed paste (`send.lua`).
- **Agent → editor**: duet starts the agent with a **per-session MCP config** pointing at `bridge/mcp.lua`, run with
  `nvim -l` (Neovim as a Lua interpreter, so there are no Node/Python/Go dependencies). The bridge speaks MCP
  (newline-delimited JSON-RPC) on stdio and talks to the parent editor through `$NVIM`, which duet sets in the agent's
  environment.
- **Blocking calls never block the editor.** The bridge submits a request to `duet.broker`, which returns an id at
  once. The handler resolves it later, e.g. when the user submits a review, and the bridge polls or is notified. The
  agent's tool timeout is raised through the adapter's env.
- **Hooks** (plan review) use the same RPC/broker path through `bridge/hook.lua`.
- **No global side effects**: all agent config (MCP config, hook settings, system prompt) is generated per session in
  `stdpath("run")/duet/<session-id>/` (mode 0600) and passed with CLI flags. Never write to the user's
  `~/.claude.json`, `~/.claude/settings.json`, or any other agent's global config.

## Module map

```
plugin/duet.lua            -- defines :Duet lazily; no work at startup
lua/duet/
  init.lua                 -- setup(), public API (send, review, …)
  config.lua               -- defaults, merge, validation
  commands.lua             -- :Duet <sub> dispatcher and completion registry
  health.lua               -- :checkhealth duet, with a check registry
  util.lua  log.lua        -- notify, paths, git root; file logger
  agents/init.lua          -- adapter registry and user overrides
  agents/claude.lua        -- Claude Code adapter
  terminal.lua             -- agent sessions (spawn, toggle, layouts)
  send.lua                 -- bracketed paste, submit, readiness
  context/                 -- providers ({file},{this},{selection},…) and templates
  links.lua  watch.lua     -- path:line links in terminal output; auto checktime
  launch.lua               -- builds the LaunchSpec (MCP server, env, system prompt)
  broker.lua               -- tool/prompt/hook registry plus pending requests
  tools/*.lua              -- MCP tools: open_file, get_context, show, request_review, review_document
  show.lua                 -- scratch document buffers
  review/source.lua        -- git ranges → files and old/new contents (pure plumbing)
  review/store.lua         -- annotation model and persistence
  review/format.lua        -- revdiff format (format and parse)
  review/ui.lua            -- review tab, file panel
  review/render/*.lua      -- renderers behind duet.Renderer (native, codediff)
  review/annotate.lua      -- add/edit/delete/navigate annotations
  review/session.lua       -- review lifecycle: submit / discard / flush
  plan.lua  history.lua
bridge/
  protocol.lua             -- MCP JSON-RPC server, pure and testable
  rpc.lua                  -- connects to the parent via $NVIM
  mcp.lua  hook.lua        -- entry points run with `nvim -l`
doc/duet.txt
tests/
```

## Core contracts

These are the main interfaces. Change them only deliberately, and update #1 and this file when you do.

**Agent adapter** (`lua/duet/agents/*.lua`):

```lua
---@class duet.Agent
---@field name string
---@field cmd string[]
---@field capabilities { mcp: boolean, plan_hook: boolean, system_prompt: boolean }
---@field launch fun(self, spec: duet.LaunchSpec): duet.LaunchPlan   -- pure: argv, env, files to write
---@field is_ready? fun(self, lines: string[]): boolean
---@field format_ref? fun(self, path: string, range?: integer[]): string  -- e.g. "@path:L10-L20"
---@field health? fun(self)                                            -- extra vim.health reports

---@class duet.LaunchSpec              -- built by the core
---@field cwd string
---@field session_id string
---@field run_dir string                -- stdpath("run")/duet/<session-id>; all plan files live here
---@field mcp? { name: string, command: string[], env: table<string,string> }
---@field hooks? { plan_review?: { command: string[], timeout_s?: integer } }
---@field system_prompt? string
---@field tool_timeout_ms? integer

---@class duet.LaunchPlan              -- returned by the adapter
---@field argv string[]
---@field env table<string,string>
---@field files { path: string, content: string }[]   -- written by the core (0600) before spawn
```

The core branches on `capabilities`, never on `agent.name`. `if agent == "claude"` must not appear outside
`agents/claude.lua`. `agents.get(name)` returns a fresh instance with the user's `config.agents[name]` overrides
(`cmd`, `args`, `env`) already applied, so adapters read `self.cmd`, `self.args` and `self.env` rather than their
defaults. `launch` must stay pure: the core writes `files` and spawns the process.

**Broker** (`lua/duet/broker.lua`): `register_tool{name, description, input_schema, handler(args, req)}`. Handlers
resolve with `req:resolve(text)` or `req:reject(err)`, and react to `req:on_cancel(fn)`. The bridge calls
`submit / poll / cancel / list_tools`. Handlers run on the main loop and must never wait synchronously for the user.

**Renderer** (`lua/duet/review/render/*.lua`): `open(file, old, new)`, `cursor_location() -> {side, line}`,
`goto(side, line)`, `windows()`, `close()`. Annotations must not depend on which renderer is in use.

**Annotation format** (revdiff-compatible, `review/format.lua`):

```
## path/file.go (file-level)
## path/file.go:43 (+)        -- added line, new-file numbering
## path/file.go:43-67 (+)     -- range
## path/file.go:18 (-)        -- removed line, old-file numbering
```

Each header is followed by the comment body. Body lines that start with `## ` get a leading space. The output must stay
byte-compatible with revdiff (`format.parse` round-trips it), so check revdiff's source when unsure.

## Conventions

- **Neovim >= 0.11**. Use `vim.system`, `vim.uv`, `jobstart({ term = true })`. No hard plugin dependencies. Optional
  integrations (snacks, telescope, codediff) are detected at runtime, with a fallback to `vim.ui.*`.
- **Clear over clever.** Small modules with one responsibility. Prefer pure functions (parsing, formatting, protocol,
  launch planning) and keep UI code thin around them.
- **Errors**: functions that can fail return `nil, err` (a string with context, e.g. `"source: invalid ref 'foo': …"`).
  Throw only on programmer errors. User-facing messages go through `duet.util.notify`. Debug detail goes through
  `duet.log` to `stdpath("log")/duet.log`. Never `print` in the bridge: **stdout belongs to the MCP protocol**, so
  diagnostics go to stderr or the log.
- **Don't block the editor.** Run git and other subprocesses through `vim.system` with callbacks. Schedule UI work
  with `vim.schedule`. Sync wrappers are for tests only. The one exception is health checks, which may run short
  synchronous subprocesses with a timeout (e.g. `claude --version`).
- **Registries and lazy loading.** Nothing under `duet.*` loads at startup, so never rely on a module registering
  itself when it loads. Built-in subcommands go in the built-in section at the bottom of `commands.lua`, and health
  checks at the bottom of `health.lua`, each with a closure that `require`s the feature module when it runs. The same
  rule applies to the broker's tools, prompts and hooks. `register()` stays public for runtime and third-party use.
- **Subcommands**: `impl(args, opts)` gets the words after the subcommand name and the user-command options;
  `opts.rest` is the raw text after the subcommand name, for free text such as `:Duet send`. Return `nil, err` to show
  an error.
- **Fail open toward the agent.** If duet breaks (parent gone, bad payload), a hook exits 0 with no output, and a tool
  returns an `isError` result instead of hanging.
- **Naming**: module tables are `M`; classes are `PascalCase` with `Class.new`; private helpers are `local function`.
  Highlight groups are `Duet*`, linked to standard groups with `default = true`. Filetypes are `duet_*`. Buffer names
  are `duet://…`.
- **Docs**: LuaLS annotations (`---@class`, `---@param`, `---@return`) on every public function and type. Each new
  command, option or tool goes into `doc/duet.txt` in the same PR.
- **Config**: every new option gets an entry in `config.schema` (the source of truth for allowed keys), a default in
  `config.defaults` when it has one, and a vimdoc entry. In the schema, mark maps keyed by the user with
  `open = true`, use `*` for per-entry fields (`["agents.*.cmd"]`), and `optional = true` for options with no default.
  Read options with `config.get()` at call time rather than caching them.
- **Logging**: `log.lua` is shared with the bridge processes, so it must not depend on UI code or other duet modules
  at load time. `$DUET_LOG_LEVEL` overrides `log_level`.
- **Tooling**: [mise](https://mise.jdx.dev) (`mise.toml`) pins StyLua and selene and defines the tasks. Run
  `mise trust && mise install` once.
- **Formatting and lint**: StyLua (`stylua.toml`) and selene (`selene.toml` + `vim.yml`). Run `mise run fmt`, then
  `mise run lint`, before committing. Test files `require("mini.test")` instead of using the `MiniTest` global.

## Testing

- Use `mini.test`, bootstrapped by `tests/minimal_init.lua`. Run with `mise run test` (uses `nvim` on `PATH`, or
  `$DUET_NVIM_BIN`; never `$NVIM`, which holds the parent socket inside a Neovim terminal). CI runs Neovim stable,
  nightly and the minimum supported 0.11 on Linux and macOS.
- Use **table-driven tests** for pure logic (parsers, formatters, protocol, launch plans, `cursor_location`). Name each
  case.
- Git-dependent tests create temporary repos with fixtures. Never touch the developer's real repo.
- Agent interaction is tested with a **fake agent** (e.g. `sh -c 'cat -v'` in the terminal) and a headless parent
  (`nvim --headless --listen <sock>`) talking to the real bridge. Tests must not require a real agent CLI or network.
- Every acceptance criterion in an issue maps to a test, or, for manual E2E criteria, a note in the PR describing what
  you ran.

## Working on an issue

1. Read #1, this file, and the issue. Check that the dependencies listed in the issue are merged.
2. Branch from `main`: `feat/<issue>-<slug>` (or `fix/…`, `docs/…`, `chore/…`).
3. Keep the PR to the issue's scope. If you find necessary work outside it, note it in the PR, or open a new issue
   instead of expanding the PR.
4. Facts about external tools (Claude Code CLI flags, hook schemas, MCP spec, other agents' CLIs) change often.
   **Verify them against current docs** rather than relying on memory, and link what you used in the PR:
   - Claude Code: https://docs.anthropic.com/en/docs/claude-code/cli-reference, `…/mcp`, `…/hooks`, `…/settings`
   - MCP: https://modelcontextprotocol.io/specification
5. Before opening the PR: `mise run fmt` then `mise run check` pass, docs are updated, and the acceptance criteria are
   checked off.
6. Commits: imperative subject (`Add broker request lifecycle`), body explaining why. Reference the issue in the PR
   (`Closes #N`). No AI attribution trailers or "generated with" lines.

## Don'ts

- Don't write to any agent's global config, or the user's dotfiles.
- Don't block the main loop waiting for the user or a subprocess.
- Don't print to stdout from `bridge/*`.
- Don't add hard dependencies on other plugins.
- Don't branch on agent name in core modules.
- Don't change the annotation format away from revdiff compatibility.
