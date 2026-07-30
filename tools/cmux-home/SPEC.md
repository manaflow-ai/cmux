# cmux home shared contract

`cmux home` renders a local session index. It does not own agent execution. It composes existing cmux state into one portable JSON document that Rust, Go, and TypeScript implementations can parse.

## Data sources

Implementations should merge these sources in order:

1. Hook sessions: `~/.cmuxterm/<agent>-hook-sessions.json` maps native agent session IDs to `workspaceId`, `surfaceId`, `cwd`, `pid`, and sanitized `launchCommand`.
2. Feed workstream: `~/.cmuxterm/workstream.jsonl` gives actionable approvals, questions, plan items, and recent agent activity.
3. Events stream: `cmux events --category feed --category agent --category workspace --category surface --cursor-file <path> --reconnect` gives live updates and resume-gap detection.
4. Snapshot commands: `cmux list-workspaces --json`, `cmux tree --json`, and focused surface queries fill labels, refs, and current focus state after a gap.
5. Native adapter data: optional transcript, status, or history reads from the agent. These must be summarized and redacted before entering shared state.

The hook session files are the authority for resume and jump targets. Feed and events are the authority for attention state. Snapshot commands are the authority for current workspace and surface existence.

## State shape

The JSON document is versioned with `schemaVersion: 1`. Field names are lower camel case. Unknown fields must be ignored.

Required top-level fields:

- `schemaVersion`: integer, currently `1`.
- `generatedAt`: ISO-8601 timestamp.
- `source`: how the state was produced, including event cursor and input file paths when known.
- `groups`: ordered groups shown by the UI. Valid group IDs are `awaiting`, `working`, and `completed`.
- `sessions`: flat list of sessions.
- `adapters`: adapter matrix for `claude`, `codex`, `opencode`, and `pi`.

Each session has:

- `id`: stable view ID, usually `<agent>:<agentSessionId>`.
- `agent`: one of `claude`, `codex`, `opencode`, or `pi`.
- `agentSessionId`: native session ID used by the adapter.
- `title`: short display title.
- `status`: `awaiting`, `working`, or `completed`.
- `updatedAt`: ISO-8601 timestamp used for sorting.
- `workspace`: `id`, optional `ref`, `cwd`, title, git metadata, and window ID.
- `surface`: `id`, optional `ref`, kind, and title.
- `activity`: latest summarized lifecycle state and confidence.
- `attention`: nullable actionable item. This is present for `awaiting` sessions.
- `resume`: native command array and confidence.
- `dispatch`: command array for sending text to the running cmux surface, or for starting the native agent when no surface exists.
- `focus`: cmux commands that jump to the workspace and surface.

The JSON Schema in `examples/home-state.schema.json` is the canonical machine-readable contract.

## Group rules

`awaiting` means the user can act now. Sources include Feed permission requests, questions, exit-plan prompts, unread agent notifications, or errors.

`working` means the agent has recent activity and no pending user action. Sources include session start, prompt submit, tool use, or active process evidence.

`completed` means the latest lifecycle signal is stop, session end, or a completed workstream item with no pending action.

If signals conflict, prefer the most recent event with this priority: `awaiting`, then `working`, then `completed`. A stale `awaiting` item that has a matching Feed resolution should be moved out of `awaiting`.

## Focus contract

The preferred focus sequence is:

```sh
cmux rpc workspace.select '{"workspace_id":"<workspaceId>"}'
cmux rpc surface.focus '{"workspace_id":"<workspaceId>","surface_id":"<surfaceId>"}'
```

Implementations may call equivalent CLI helpers. The operation is a no-op if the hook session no longer maps to a live workspace or surface.

## Adapter matrix

### Claude Code

- Agent key: `claude`
- Hook session file: `~/.cmuxterm/claude-hook-sessions.json`
- Install path: wrapper-injected settings through cmux.
- Resume command: `claude --resume <session_id>`
- Dispatch command: `claude <prompt>` for a new task, or send text to an existing cmux surface.
- Feed support: high for `PermissionRequest`, medium for plan and question shaping through Claude hook context.
- Known gaps: exact resume flags can come from saved `launchCommand`; use them when present. Transcript summaries are useful but should not be required.

### Codex

- Agent key: `codex`
- Hook session file: `~/.cmuxterm/codex-hook-sessions.json`
- Install path: `cmux hooks setup codex`
- Resume command: `codex resume <session_id>`
- Dispatch command: `codex <prompt>` for a new task, or send text to an existing cmux surface.
- Feed support: high for `PermissionRequest`; medium for `PreToolUse` telemetry.
- Known gaps: stock Codex plan questions and `request_user_input` stay inside the Codex TUI path today.

### OpenCode

- Agent key: `opencode`
- Hook session file: `~/.cmuxterm/opencode-hook-sessions.json`
- Install path: `cmux hooks setup opencode`, plus optional `cmux hooks opencode install --project`
- Resume command: `opencode --session <session_id>`
- Dispatch command: `opencode <prompt>` for a new task, or send text to an existing cmux surface.
- Feed support: high through the OpenCode plugin event bus when `cmux-feed.js` is installed.
- Known gaps: project-local plugin installation is opt-in, so global and project config can disagree.

### Pi

- Agent key: `pi`
- Hook session file: `~/.cmuxterm/pi-hook-sessions.json`
- Install path: `cmux hooks setup pi`
- Resume command: `pi --session <session_id>`
- Dispatch command: `pi <prompt>` for a new task, or send text to an existing cmux surface.
- Feed support: low. Pi currently provides lifecycle and restore hooks only.
- Known gaps: no Feed approval bridge yet, so awaiting state is usually inferred from notifications or lifecycle heuristics.

## Customization

Customizations belong in `config` so renderers can stay portable:

- `groupOrder`: list of group IDs.
- `hiddenAgents`: agent keys to hide.
- `density`: `compact`, `comfortable`, or `spacious`.
- `accentByAgent`: optional color tokens keyed by agent.

Implementations may add local preference files, but exported state should keep the portable `config` object.

## CLI contract

All implementations should accept:

```sh
cmux-home --data <path> --once
```

The command should:

- Read the supplied state file.
- Validate `schemaVersion`.
- Print counts by group and agent.
- Exit 0 without launching a TUI or changing cmux state.

Interactive implementations can add their own flags. `--state <path> --summary --non-interactive` is an accepted alias, and the shared smoke helper tries it if `--data <path> --once` is not recognized.

## Privacy

Shared state should keep operational identifiers and short summaries. Do not store raw prompts, tool arguments, file contents, credentials, or full transcript text. Use `promptSummary`, `lastMessage`, and `summary` as redacted display fields.
