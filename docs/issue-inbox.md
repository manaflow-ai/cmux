# Issue Inbox

Issue Inbox aggregates GitHub Issues and Linear issues into one cmux surface. It paints from a local disk cache first, then refreshes configured sources in the background. Each row can spawn a cmux workspace for the issue.

## Config

Create `~/.config/cmux/issue-inbox.json`:

```json
{
  "sources": [
    {
      "type": "github",
      "repo": "manaflow-ai/cmux",
      "projectRoot": "~/fun/cmuxterm-hq/repo",
      "spawn": {
        "devServerCommand": "cd web && bun dev",
        "webURL": "http://localhost:3000",
        "defaultAgent": "claude"
      }
    },
    {
      "type": "linear",
      "teamKey": "ENG",
      "projectRoot": "~/dev/thing",
      "apiKeyEnvVar": "LINEAR_API_KEY"
    }
  ],
  "autoRefreshSeconds": 0
}
```

`autoRefreshSeconds` is parsed for future use. In V1, `0` means off and no polling timer runs.

Bad source entries are skipped and recorded as config warnings. Unknown keys are ignored. `projectRoot` supports `~` expansion and is used by Spawn Workspace when no explicit `--cwd` is passed.

The optional `spawn` object controls workspace setup:

| Key | Meaning |
| --- | --- |
| `devServerCommand` | Command for the bottom-right dev server terminal. |
| `webURL` | URL for the top-right browser surface. |
| `defaultAgent` | `claude`, `codex`, or `none` when no caller passes an agent. |
| `agentCommandTemplate` | Optional command template with `{prompt}`, `{url}`, `{number}`, and `{title}` placeholders. |

## Auth

GitHub uses the first available token source:

1. `GH_TOKEN`
2. `GITHUB_TOKEN`
3. `gh auth token`

Linear uses the configured `apiKeyEnvVar`, or `LINEAR_API_KEY` when omitted.

## CLI

```bash
cmux issues list [--json]
cmux issues refresh [--json]
cmux issues open
cmux issues spawn <issue-id> [--cwd <path>] [--agent claude|codex|none] [--json]
```

`list` prints cached rows and does not force a refresh. `refresh` fetches all configured sources and isolates failures per source. `open` opens or focuses the Issue Inbox surface in the current workspace.

## Spawn Workspace

`cmux issues spawn` and the row action call the same `issues.spawn_workspace` socket method.

Spawn is create-or-reuse:

1. If the issue already maps to a live workspace, cmux selects that workspace and returns `reused: true`.
2. Otherwise cmux creates a workspace through the normal `workspace.create` path.

The workspace title is `"<number> <title>"`, truncated to about 60 characters. The working directory is `--cwd` when provided, otherwise the source `projectRoot`. If neither exists, the call fails with `invalid_params`.

When `spawn.webURL` or `spawn.devServerCommand` exists, cmux creates a layout:

1. Left pane, 50 percent width: focused terminal running `claude <prompt>`, `codex <prompt>`, or a plain shell for `none`.
2. Right pane: top browser for `webURL`, bottom terminal running `devServerCommand`.

If only one right-side target is configured, the right side contains only that browser or terminal. If no right-side target is configured and an agent is selected, cmux creates a single terminal running the agent command. If no right-side target is configured and the agent is `none`, cmux keeps the current single-terminal workspace behavior.

The default prompt is:

```text
Work on GitHub issue manaflow-ai/cmux#123: <title> (<url>)
```

`agentCommandTemplate` replaces `{prompt}`, `{url}`, `{number}`, and `{title}` with shell-escaped values.

Each spawned workspace receives:

```text
CMUX_ISSUE_ID
CMUX_ISSUE_URL
CMUX_ISSUE_TITLE
CMUX_ISSUE_PROVIDER
```

The workspace description stores the issue title and source URL.

## Socket Methods

```text
issues.list
issues.refresh
issues.open
issues.spawn_workspace
```

`issues.list` returns cached `items`, `source_errors`, `fetched_at`, and config metadata. `issues.refresh` returns per-source counts or errors. `issues.open` returns the surface ref. `issues.spawn_workspace` accepts `{ "issue_id": "...", "cwd": "...", "agent": "claude" }`, where `cwd` and `agent` are optional.

## Adapter Contract

New providers implement `IssueSourceAdapter` in `Packages/macOS/CmuxIssueInbox`:

```swift
public protocol IssueSourceAdapter: Sendable {
    var sourceID: String { get }
    var displayName: String { get }
    func fetchIssues() async throws -> [IssueInboxItem]
}
```

Adapters normalize provider data into `IssueInboxItem`. The UI, filters, cache, socket methods, CLI, and workspace spawn path consume only that normalized model, so adding a provider should not require UI changes.
