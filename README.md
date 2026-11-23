# duet.nvim

> **Work in progress.** Nothing here is usable yet. See the
> [architecture & roadmap](https://github.com/ksysoev/duet.nvim/issues/1).

duet is a Neovim plugin for pairing with AI coding agents. It runs the agent CLI in a Neovim terminal and sends it
context (files, selections, diagnostics, prompt templates). It lets the agent drive the editor through an MCP server
(open files, show documents, read editor context). And it adds a review loop: annotate diffs, documents and plans line
by line, and hand the result back to the agent in the [revdiff](https://github.com/umputun/revdiff) annotation format.
duet is agent-agnostic; Claude Code is the first supported agent.

## Requirements

- Neovim >= 0.11

## Development

Tooling is managed with [mise](https://mise.jdx.dev):

```sh
mise trust && mise install   # once: installs the pinned StyLua and selene
mise run fmt                 # format
mise run check               # lint + tests (run before opening a PR)
```

Tests use [mini.test](https://github.com/nvim-mini/mini.nvim), which is cloned into `.tests/` on first run. They use
the `nvim` on your `PATH`; set `DUET_NVIM_BIN` to test another binary. To try the plugin in a clean editor:
`nvim --clean -u tests/minimal_init.lua`.

See [AGENTS.md](AGENTS.md) for architecture and contribution guidelines.
