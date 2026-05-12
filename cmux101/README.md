# cmux101

An agentic coding CLI that picks the best ideas from Codex CLI, Claude Code, and
OpenCode — then adds first-class integration with
[cmux](https://github.com/manaflow-ai/cmux), the Ghostty-based macOS terminal
built for AI coding agents.

```
  $ cmux101 "find the slowest test in this repo and propose a fix"
  $ cmux101 -p "summarize what changed in the last 5 commits"
  $ cmux101 "open a new cmux pane and tail the build log there"
```

cmux101 runs on **Bun + TypeScript**. It speaks to **Anthropic, OpenAI, Google
Gemini, OpenRouter, AWS Bedrock, Google Vertex, Ollama, and LM Studio**. When
cmux is present it gains 25 native tools that drive `cmux send`, `cmux new-pane`,
`cmux tree`, `cmux browser ...` — so the agent can orchestrate your terminal as
fluently as it edits files.

## Status

Working end-to-end. **602 tests pass**, `tsc --noEmit` is clean. The model
plumbing covers 8 providers, the tool surface is 41 tools (matches claw-code's
40+ at the schema level), the agent loop streams text + tools, and the cmux
integration drives ~25 of cmux's CLI surface points. Verified live: text-only
turns, multi-tool turns, todo-write planning, cmux pane creation + send +
read-screen, OAuth fallback to Claude Code's keychain credentials.

## Feature surface

* **Providers**: Anthropic, OpenAI, Gemini, OpenRouter, Bedrock, Vertex,
  Ollama, LM Studio — one normalized `StreamEvent` shape regardless.
* **Model routing (OpenCode-style)**: `provider/model` form, alias table
  (`opus`, `sonnet`, `haiku`, `gpt5`, `gpt4o`, `flash`, `pro`), prefix routing,
  user-defined aliases in config.
* **Tools** (built-in, 41): `file_read/write/edit`, `shell`, `glob`, `grep`,
  `web_fetch`, `web_search`, `notebook_edit`, `repl` (python/node),
  `subagent_spawn(_many)`, `todo_write/list/update`, `enter/exit_plan_mode`,
  `sleep`, `config_read`, `structured_output`, `lsp` (stub), memory tools,
  MCP-bridged tools, **25 cmux_* tools** (tree, send, new_pane, new_workspace,
  read_screen, browser, notify, …), `cmux_raw` escape hatch.
* **Permissions**: `read-only`, `workspace-write`, `danger-full-access`,
  `plan`, `default`, `auto`. Interactive `(y / s / a / n)` prompts in TUI,
  safe deny in headless without `--auto`.
* **Sessions**: append-only JSONL transcripts. User-scope (`~/.cmux101/`) and
  project-scope (`<cwd>/.cmux101/`) storage. `worker_state.json` for IDE
  attachment.
* **CLAUDE.md context loading** (claw-code parity): walks `cwd` to git root,
  picks up `CLAUDE.md`, `AGENTS.md`, `.cmux101/CLAUDE.md`, and
  `~/.cmux101/CLAUDE.md`. Size-capped (32 KB/file, 128 KB total).
* **`cmux101 init`**: bootstraps `CLAUDE.md`, `.cmux101/config.json`, sessions
  dir, gitignore entries. Idempotent.
* **`cmux101 doctor`**: 8 preflight checks (bun version, cmux availability,
  providers configured, writable home, CLAUDE.md, tool registration,
  model listing, OAuth discovery). `--output-format json` for scripts.
* **Print mode**: tool result summaries (with `file_edit` diff coloring and
  compact shell output), `--quiet` for terse, `--output-format json` for
  NDJSON event streaming, `--show-cost` for per-turn token + USD totals.
* **Slash commands**: `/help`, `/clear`, `/quit`, `/model`, `/resume`,
  `/skills`, `/memory`, `/tools`, `/status`, `/cost`, `/permissions`,
  `/export`, `/init`, `/doctor`, `/compact`.
* **Hooks**: subprocess JSON protocol (`pass` / `block` / `transform`).
* **Skills**: markdown-with-frontmatter and executable shell scripts under
  `.cmux101/skills/` (project) or `~/.cmux101/skills/` (user).
* **MCP client**: stdio + sse + http transports; tools surface as
  `mcp__<server>__<tool>`.
* **Auto-memory**: `~/.cmux101/memory/` + `.cmux101/memory/` with
  user/feedback/project/reference scopes, indexed in `MEMORY.md`.
* **Auth**: env vars → OS keychain → file fallback; also auto-discovers
  Claude Code's keychain OAuth and Codex's `~/.codex/auth.json` so users with
  an existing subscription don't need an API key.

## Install

You need Bun ≥ 1.2.

```bash
git clone https://github.com/manaflow-ai/cmux.git
cd cmux/cmux101
bun install
bun run src/cli/index.ts --help
```

Or build a single binary:

```bash
bun run build              # → dist/cmux101 (darwin-arm64)
./dist/cmux101 --help
```

## Configure a provider

cmux101 reads API keys from environment variables first, then the OS keychain
(macOS Keychain / Linux `secret-tool` / Windows `wincred`), then a chmod-600
file at `~/.cmux101/credentials.json`.

```bash
# Pick whichever you have. Anthropic and OpenAI work out of the box.
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GEMINI_API_KEY=AIza...
export OPENROUTER_API_KEY=sk-or-...

# Or store keys in the OS keychain:
cmux101 auth login anthropic
```

For Bedrock and Vertex, the SDK reads your normal cloud credentials (AWS
profile or ADC). Ollama and LM Studio are auto-detected on `localhost:11434`
and `localhost:1234`.

```bash
cmux101 models                  # list every configured provider's catalogue
cmux101 models openrouter       # one provider
```

## Use it

```bash
# Interactive TUI in the current dir
cmux101

# Headless one-shot, piped to other tools
cmux101 -p "explain this diff" < <(git diff HEAD~1)

# Pick a provider/model
cmux101 -p --provider openai -m gpt-4o "refactor src/auth.ts"

# Resume a past session
cmux101 sessions
cmux101 --resume <id>

# Hand-edit permissions: "plan mode" allows only read tools
cmux101 --plan "audit src/ for SQL injection risks"
```

## cmux integration

If `cmux` is on your PATH, cmux101 registers 25 native tools the model can call:

| Tool | What it does |
|---|---|
| `cmux_tree` | Snapshot of all windows, workspaces, panes, surfaces |
| `cmux_send` / `cmux_send_key` | Type text or send named keys to a terminal surface |
| `cmux_read_screen` | Capture the visible (or full-scrollback) contents of a terminal |
| `cmux_new_pane` / `cmux_new_split` | Create panes, split surfaces |
| `cmux_new_workspace` / `cmux_select_workspace` | Manage workspaces |
| `cmux_notify` / `cmux_set_status` / `cmux_set_progress` / `cmux_log` | Surface progress in the cmux UI |
| `cmux_browser_*` (8 tools) | Drive the cmux browser surface — navigate, click, type, screenshot, snapshot the accessibility tree |
| `cmux_raw` (escape hatch) | Run any `cmux <subcmd>` with arbitrary args |

When `$CMUX_WORKSPACE_ID` is set (which cmux does inside its panes), every tool
defaults to "this workspace" so the agent operates locally without juggling IDs.

```bash
cmux101 "open a new pane to the right and run \`watch -n 1 'date'\`"
cmux101 "find any process bound to port 3000 and kill it, then start \`bun dev\` in a new pane"
cmux101 "navigate the cmux browser to https://news.ycombinator.com and screenshot it"
```

## Architecture (one paragraph)

The runner is a single agent loop: append user message → `provider.stream(req)`
→ pipe normalized `StreamEvent`s into the UI → on `tool_call_end`, execute the
tool concurrently with permissions enforcement, hooks, and (for the `shell` and
`subagent_spawn_many` tools) streaming output → append a tool-role message →
repeat until `message_stop` with no further tool calls. Providers normalize
into a common event stream; tools are plain zod-typed async functions; the TUI
is Ink (React for terminals); sessions live as append-only JSONL on disk. See
`ARCHITECTURE.md` for diagrams and `CHOICES.md` for the engineering rationale.

## Layout

```
cmux101/
├── CHOICES.md             ← language & framework decisions
├── ARCHITECTURE.md        ← diagrams + module boundaries
├── src/
│   ├── core/              ← runner, session, transcript, permissions
│   ├── providers/         ← 8 provider adapters + registry
│   ├── tools/             ← built-in tools (file, shell, search, web, mcp, subagent)
│   │   └── cmux/          ← 25 cmux integration tools
│   ├── tui/               ← Ink components
│   ├── headless/          ← --print mode
│   ├── cli/               ← arg parsing, auth, config, entry
│   ├── hooks/             ← user-defined event hooks
│   ├── skills/            ← slash-command loader
│   ├── memory/            ← auto-memory store
│   └── mcp/               ← MCP client
└── tests/                 ← 393 unit + integration tests
```

## Tests

```bash
bun test                          # full suite
bun test tests/unit/              # unit only (no live cmux)
bun test tests/integration/       # live cmux required
bun tsc --noEmit                  # typecheck
```

## Slash commands and hooks

Drop markdown files in `~/.cmux101/skills/` or `<project>/.cmux101/skills/`:

```markdown
---
name: review
description: Review the current diff
---
Run `git diff` and call out:
1. Bugs and likely regressions
2. Missing tests
3. Style/perf concerns

{{args}}
```

Then `cmux101` → `/review` invokes the skill. Shell scripts with the exec bit
work too; first comment line is the description.

Hooks live in `~/.cmux101/config.json`:

```json
{
  "hooks": [
    { "event": "tool.pre", "matcher": "^shell$", "command": "logger -t cmux101" }
  ]
}
```

Each hook is a subprocess that gets the event JSON on stdin and returns a
`{action: "pass"|"block"|"transform", data?: ..., message?: ...}` JSON on stdout.

## Subagents

cmux101 exposes `subagent_spawn` and `subagent_spawn_many` as tools. Subagents
get a narrowed permission set and an optional `isolation: "worktree"` flag that
runs them inside a fresh `git worktree`. Useful for "go investigate X without
touching my working tree" delegation.

## MCP

cmux101 is an MCP client. Configure servers in `~/.cmux101/config.json`:

```json
{
  "mcp": [
    {
      "name": "github",
      "transport": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" }
    }
  ]
}
```

Each remote tool becomes available as `mcp__<server>__<tool>` and defaults to
`"ask"` permission.

## Inspirations and credits

cmux101 is an **original implementation**. It takes architectural cues from:

- [Codex CLI](https://github.com/openai/codex) — single-binary distribution and sandboxed shell
- [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) — tool design, hooks, skills, auto-memory
- [OpenCode](https://github.com/sst/opencode) — provider-agnostic core, MCP client posture

No source code was copied from those projects.

## License

Apache 2.0 (matches the parent cmux repository).
