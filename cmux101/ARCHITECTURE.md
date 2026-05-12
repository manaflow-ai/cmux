# cmux101 — Architecture

## High-level shape

```
                           ┌──────────────────────────┐
                           │         entry points     │
                           │  ┌──────────┐ ┌─────────┐│
                           │  │   TUI    │ │ --print ││
                           │  │  (Ink)   │ │ headless││
                           │  └────┬─────┘ └────┬────┘│
                           └───────┼────────────┼─────┘
                                   │            │
                                   ▼            ▼
                           ┌──────────────────────────┐
                           │         Session          │
                           │  - id, cwd, model        │
                           │  - transcript (JSONL)    │
                           │  - permissions           │
                           │  - hooks registry        │
                           │  - skills registry       │
                           └────────────┬─────────────┘
                                        │
                                        ▼
                           ┌──────────────────────────┐
                           │          Runner          │
                           │  agent loop:             │
                           │   1. send msgs to model  │
                           │   2. stream events       │
                           │   3. on tool_use → run   │
                           │      tool, append result │
                           │   4. repeat until stop   │
                           └──┬──────────────────┬────┘
                              │                  │
                              ▼                  ▼
                  ┌──────────────────┐  ┌──────────────────┐
                  │   Provider       │  │   Tool runner    │
                  │   abstraction    │  │   (permissions,  │
                  │                  │  │    subagents,    │
                  │  stream(req)     │  │    hooks, MCP)   │
                  │     → events     │  │                  │
                  └────────┬─────────┘  └────────┬─────────┘
                           │                     │
              ┌────────────┼────────────┐        │
              ▼            ▼            ▼        ▼
        ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────────┐
        │Anthropic│  │ OpenAI  │  │ Gemini  │  │  tools/             │
        │ adapter │  │ adapter │  │ adapter │  │   - file.read       │
        └─────────┘  └─────────┘  └─────────┘  │   - file.write      │
        ┌─────────┐  ┌─────────┐  ┌─────────┐  │   - file.edit       │
        │Bedrock  │  │ Vertex  │  │OpenRouter│ │   - shell.run       │
        │ adapter │  │ adapter │  │ adapter  │ │   - web.fetch       │
        └─────────┘  └─────────┘  └─────────┘  │   - web.search      │
        ┌──────────────────────┐                │   - glob, grep      │
        │ Local (Ollama/LMStudio)              │   - subagent.spawn  │
        └──────────────────────┘                │   - mcp.*           │
                                                │   - cmux.*  (opt)   │
                                                └─────────────────────┘
```

## The agent loop, in one paragraph

`runner.run()` takes a `Session` and a user message, appends the message to
the transcript, asks the `Provider` to stream a response, and pipes the
`StreamEvent`s into the TUI (or `--print` writer). When it sees a
`tool-call` event, it asks `ToolRunner` to execute it, awaiting the result
(or, for streaming tools like `shell.run`, forwarding output deltas back to
the TUI). The tool result is appended as a tool message, and the runner
issues another `stream()` call. This continues until the provider emits a
`message-stop` with no further tool calls, or `abortSignal` is fired.

## Directory layout (under `cmux101/`)

```
cmux101/
├── package.json
├── tsconfig.json
├── bunfig.toml
├── CHOICES.md
├── ARCHITECTURE.md
├── README.md
├── VISION.md
├── bin/
│   └── cmux101              # tiny wrapper that bun runs
├── src/
│   ├── core/
│   │   ├── types.ts         # all shared interfaces
│   │   ├── session.ts
│   │   ├── runner.ts
│   │   ├── transcript.ts
│   │   ├── permissions.ts
│   │   └── errors.ts
│   ├── providers/
│   │   ├── index.ts         # registry
│   │   ├── anthropic.ts
│   │   ├── openai.ts
│   │   ├── gemini.ts
│   │   ├── openrouter.ts
│   │   ├── bedrock.ts
│   │   ├── vertex.ts
│   │   └── local.ts         # ollama + lmstudio
│   ├── tools/
│   │   ├── index.ts         # built-in registry
│   │   ├── file_read.ts
│   │   ├── file_write.ts
│   │   ├── file_edit.ts
│   │   ├── glob.ts
│   │   ├── grep.ts
│   │   ├── shell.ts
│   │   ├── web_fetch.ts
│   │   ├── web_search.ts
│   │   ├── subagent.ts
│   │   ├── mcp.ts
│   │   └── cmux/            # cmux integration tool pack
│   │       ├── index.ts
│   │       ├── send.ts
│   │       ├── new_pane.ts
│   │       ├── tree.ts
│   │       ├── read_screen.ts
│   │       └── ...
│   ├── tui/
│   │   ├── app.tsx
│   │   ├── messages.tsx
│   │   ├── input.tsx
│   │   └── theme.ts
│   ├── headless/
│   │   └── print.ts
│   ├── cli/
│   │   ├── index.ts         # arg parsing, mode dispatch
│   │   ├── auth.ts
│   │   └── config.ts
│   ├── hooks/
│   │   └── index.ts
│   ├── skills/
│   │   └── index.ts
│   ├── memory/
│   │   └── index.ts         # auto-memory module
│   └── mcp/
│       └── client.ts
└── tests/
    ├── unit/
    │   └── providers/...
    ├── integration/
    │   └── tool_runner.test.ts
    └── e2e/
        └── cmux_integration.test.ts
```

## Core types (the contract subagents work against)

See `src/core/types.ts` for the canonical definitions. Summary:

* `Message` — `{ role: 'system'|'user'|'assistant'|'tool', content: Content[] }`
  with `Content` being a tagged union of `text`, `tool_use`, `tool_result`,
  `image`, `thinking`.
* `StreamEvent` — `text_delta`, `thinking_delta`, `tool_call_start`,
  `tool_call_input_delta`, `tool_call_end`, `message_stop`, `usage`,
  `error`. Providers emit these; runner consumes them.
* `Tool` — `{ name, description, inputSchema (zod), run(input, ctx) }`
  where `run` returns an `AsyncIterable<ToolEvent> | ToolResult`.
* `Provider` — `{ id, listModels(), stream(req) -> AsyncIterable<StreamEvent> }`.
* `ToolContext` — `{ session, permissions, abortSignal, dispatcher, cwd }`.

## How subagents work

`tools/subagent.ts` exposes a `subagent.spawn` tool. The dispatcher:

1. Builds a child `Session` with a narrowed `permissions` and (optionally) a
   subset of tools. Different `system` prompt is allowed.
2. Optionally creates a worktree (`isolation: 'worktree'`) by shelling out
   to `git worktree add`.
3. Runs the child runner to completion, capturing its transcript.
4. Returns the child's final assistant message as the tool result.

Parallel dispatch is supported via `subagent.spawn_many`, which spawns N
children concurrently and waits for all.

## How cmux integration works

When cmux is present (`cmux --version` succeeds), `tools/cmux/index.ts`
registers a tool pack. Tools shell out to `cmux <subcommand>` using `Bun.$`
for safe argument quoting. Each cmux subcommand maps to one tool:

| cmux subcommand | tool name |
|---|---|
| `cmux send` | `cmux_send` |
| `cmux new-pane` | `cmux_new_pane` |
| `cmux new-workspace` | `cmux_new_workspace` |
| `cmux tree` | `cmux_tree` |
| `cmux read-screen` | `cmux_read_screen` |
| `cmux notify` | `cmux_notify` |
| `cmux browser …` | `cmux_browser_*` |
| (and so on for ~40 subcommands) |

The pack also exposes a lower-level `cmux_raw` escape hatch that takes a
JSON array of args, for cmux commands we have not wrapped yet.

When `$CMUX_WORKSPACE_ID` is set (we're running inside a cmux pane), all
cmux tools default their `--workspace` to that ID, so the agent operates on
"its own" cmux workspace by default.

## Concurrency model

* The runner is single-threaded but heavily async. One in-flight provider
  call at a time within a session.
* Subagents run as independent runners, each with its own model call in
  flight. They share the host process but never the same `Session`.
* Tool calls within one assistant turn are batched: the runner collects all
  `tool_call_end` events from the turn, executes them concurrently
  (`Promise.allSettled`), and feeds the results back together on the next
  turn.

## Failure & cancellation

`AbortController` propagates through `Session.abortSignal`. SIGINT in TUI
mode triggers `abort()` on the current runner; running tools see the signal
on their `ctx.abortSignal` and are expected to clean up. The transcript
records an `aborted` event so resumed sessions know where they stopped.
