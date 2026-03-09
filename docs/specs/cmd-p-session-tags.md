# Spec: Claude Code Session Topic Tags in Cmd-P Switcher

## Problem

When you have many workspaces running Claude Code, cmd-p shows them all as "Claude Code" with minimal differentiation. If a session was discussing "open claw", there's no way to search "open claw" in cmd-p and find that workspace.

## How It Works Today

1. **Cmd-P switcher** lists workspaces with search keywords derived from: workspace name, working directory, git branch, listening ports
2. **Claude hook sessions** (`~/.cmuxterm/claude-hook-sessions.json`) track `lastSubtitle` and `lastBody` from Claude Code notifications — but this data is **never fed into cmd-p search keywords**
3. `CommandPaletteSwitcherSearchMetadata` only has `directories`, `branches`, `ports`

## Settings

Feature is **disabled by default**. Users opt in via cmux settings:

```text
cmux settings set cmd-p-session-tags true
```

Or via the settings UI / config file (`~/.cmuxterm/settings.json`):

```json
{
  "cmdPSessionTags": false
}
```

When disabled:
- No tags are extracted from Claude notifications
- No tag tokens appear in cmd-p search keywords
- No tag footnotes render in cmd-p rows
- `workspace.set_tags` socket command still works (manual tags always available)

When enabled:
- Claude hook notifications extract topic tags and push them to the workspace
- Tags appear as searchable keywords and visual footnotes in cmd-p

## Proposed Design

**Add a `tags: [String]` field to the search metadata** so that Claude Code session context (topics, keywords, recent activity) becomes searchable in cmd-p.

### Data Flow

```text
Claude Code hook (notification/stop)
  → cmux claude-hook notification (CLI)
    → upserts lastSubtitle/lastBody into session store
    → NEW: also sends topic tags via socket command (if setting enabled)

Socket command: workspace.set_tags <workspace-id> --source <source-key> <json-array>
  → Workspace model stores tags by source namespace
    → cmd-p search indexer includes tags in keywords
```

### Tag Namespacing

Tags are stored **per source** to avoid conflicts between Claude hooks and manual user tags:

```swift
// Workspace model
@Published var tagsBySource: [String: [String]] = [:]
// e.g. { "claude:abc-123": ["open claw", "refactor"], "manual": ["auth", "payments"] }

var searchTags: [String] {
    tagsBySource.values.flatMap { $0 }
}
```

- **Claude hooks** use source `claude:<sessionId>` — replaced per-session, other sessions and manual tags are untouched
- **Manual CLI** uses source `manual` — never overwritten by Claude hooks
- On `claude-hook stop`, only tags for that session's source key are removed

### Changes

#### 1. `CommandPaletteSwitcherSearchMetadata` — add `tags` field

```swift
struct CommandPaletteSwitcherSearchMetadata: Equatable, Sendable {
    let directories: [String]
    let branches: [String]
    let ports: [Int]
    let tags: [String]  // NEW
}
```

#### 2. `CommandPaletteSwitcherSearchIndexer` — index tags as keywords

In `metadataKeywordsForSearch`, add tag tokens:

```swift
let tagTokens = metadata.tags.flatMap { tagTokensForSearch($0) }
// Split on delimiters like branches, so "open-claw" matches "open", "claw", "open-claw"
if !tagTokens.isEmpty {
    contextKeywords.append(contentsOf: ["tag", "topic", "claude"])
}
```

#### 3. `Workspace` model — add `tagsBySource: [String: [String]]`

Persisted in workspace snapshot so tags survive restarts. Caps:
- Max 10 sources
- Max 20 tags per source
- Each tag max 100 chars

Computed `searchTags` flattens all sources for search indexing.

#### 4. `commandPaletteWorkspaceSearchMetadata` — feed tags into metadata

```swift
return CommandPaletteSwitcherSearchMetadata(
    directories: directories,
    branches: branches,
    ports: ports,
    tags: workspace.searchTags  // NEW — gated on cmdPSessionTags setting for display
)
```

#### 5. Socket command: `workspace.set_tags`

```text
workspace.set_tags <workspace-id> --source <source-key> ["tag1","tag2","tag3"]
workspace.clear_tags <workspace-id> --source <source-key>
```

- Replaces tags **for the given source only** — other sources are untouched
- `--source` is required; callers declare ownership
- Off-main parsing, `DispatchQueue.main.async` for the model update (per socket threading policy)

#### 6. Claude hook pipeline — extract and push tags

In the `claude-hook notification` handler, after upserting the session record:
- **Check setting**: skip tag extraction if `cmdPSessionTags` is disabled
- Extract topic keywords from `summary.subtitle` and `summary.body` (simple word tokenization, filter stopwords, keep meaningful tokens)
- **Sanitize**: strip tokens that look like secrets, file paths, UUIDs, emails, or other PII patterns before persisting
- Send `workspace.set_tags --source claude:<sessionId>` with the extracted tags
- On `claude-hook stop`, send `workspace.clear_tags --source claude:<sessionId>`

#### 7. CLI: `cmux workspace set-tags` — manual tag setting

```text
cmux workspace set-tags 1 "open claw" "refactor"
cmux workspace clear-tags 1
```

Manual tags use source `manual` and are never overwritten by Claude hooks.

### What Users See

- Cmd-P with no query: same as today (workspace names, directories, etc.)
- Type "open claw" → the workspace where Claude was discussing open claw appears in results
- Tags shown as faint footnote text below the workspace subtitle

### Display in Cmd-P Row

```text
┌─────────────────────────────────────┐
│ my-project                          │
│ Workspace • ~/Dev/my-project        │
│ open claw · refactor · auth    ← faint tag footnotes
└─────────────────────────────────────┘
```

### Tag Sources (priority order)

1. **Claude notification body** — richest signal (e.g., "Finished refactoring the auth module")
2. **Claude notification subtitle** — shorter but still useful (e.g., "Task complete")
3. **Manual user tags** via CLI — explicit, stored under `manual` source, never overwritten

### Edge Cases

- **Multiple Claude sessions per workspace**: each session writes to its own `claude:<sessionId>` source — no conflicts
- **Session ends**: only that session's tags are cleared; manual and other session tags persist
- **Tag overflow**: caps enforced per source (20 tags, 100 chars each); oldest dropped if exceeded
- **No Claude session**: tags field is empty, no UI change
- **Feature disabled** (default): no automatic tag extraction, socket commands still work for manual use
- **Sensitive data**: tag extraction sanitizes secrets/PII patterns before persisting

## Key Files

| File | Change |
|------|--------|
| `Sources/ContentView.swift` | `CommandPaletteSwitcherSearchMetadata` + indexer + row display |
| `Sources/Workspace.swift` | `tagsBySource` property + snapshot persistence |
| `Sources/AppDelegate.swift` | `workspace.set_tags` / `workspace.clear_tags` socket command handlers |
| `CLI/cmux.swift` | Tag extraction in `claude-hook notification`, `workspace set-tags` CLI, settings check |
| `Sources/Settings/` | `cmdPSessionTags` setting (default `false`) |
