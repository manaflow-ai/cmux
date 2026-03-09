# Spec: Claude Code Session Topic Tags in Cmd-P Switcher

## Problem

When you have many workspaces running Claude Code, cmd-p shows them all as "Claude Code" with minimal differentiation. If a session was discussing "open claw", there's no way to search "open claw" in cmd-p and find that workspace.

## How It Works Today

1. **Cmd-P switcher** lists workspaces with search keywords derived from: workspace name, working directory, git branch, listening ports
2. **Claude hook sessions** (`~/.cmuxterm/claude-hook-sessions.json`) track `lastSubtitle` and `lastBody` from Claude Code notifications — but this data is **never fed into cmd-p search keywords**
3. `CommandPaletteSwitcherSearchMetadata` only has `directories`, `branches`, `ports`

## Proposed Design

**Add a `tags: [String]` field to the search metadata** so that Claude Code session context (topics, keywords, recent activity) becomes searchable in cmd-p.

### Data Flow

```
Claude Code hook (notification/stop)
  → cmux claude-hook notification (CLI)
    → upserts lastSubtitle/lastBody into session store
    → NEW: also sends topic tags via socket command

Socket command: workspace.set_tags <workspace-id> <json-array>
  → Workspace model stores tags: [String]
    → cmd-p search indexer includes tags in keywords
```

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

#### 3. `Workspace` model — add `@Published var searchTags: [String]`

Persisted in workspace snapshot so tags survive restarts. Capped at ~20 tags, each max 100 chars.

#### 4. `commandPaletteWorkspaceSearchMetadata` — feed tags into metadata

```swift
return CommandPaletteSwitcherSearchMetadata(
    directories: directories,
    branches: branches,
    ports: ports,
    tags: workspace.searchTags  // NEW
)
```

#### 5. New socket command: `workspace.set_tags`

```
workspace.set_tags <workspace-id> ["tag1","tag2","tag3"]
```

- Replaces all tags (not additive) — the source of truth is the caller
- Off-main parsing, `DispatchQueue.main.async` for the model update (per socket threading policy)

#### 6. Claude hook pipeline — extract and push tags

In the `claude-hook notification` handler, after upserting the session record:
- Extract topic keywords from `summary.subtitle` and `summary.body` (simple word tokenization, filter stopwords, keep meaningful tokens)
- Send `workspace.set_tags` with the extracted tags
- On `claude-hook stop`, clear the tags (or leave stale — TBD, probably clear)

#### 7. (Optional) CLI: `cmux workspace set-tags` — manual tag setting

Allow users to manually tag workspaces: `cmux workspace set-tags 1 "open claw" "refactor"`

### What Users See

- Cmd-P with no query: same as today (workspace names, directories, etc.)
- Type "open claw" → the workspace where Claude was discussing open claw appears in results
- Tags shown as faint footnote text below the workspace subtitle: `Tags: open claw, refactor, auth`

### Display in Cmd-P Row

```
┌─────────────────────────────────────┐
│ my-project                          │
│ Workspace • ~/Dev/my-project        │
│ open claw · refactor · auth    ← faint tag footnotes
└─────────────────────────────────────┘
```

### Tag Sources (priority order)

1. **Claude notification body** — richest signal (e.g., "Finished refactoring the auth module")
2. **Claude notification subtitle** — shorter but still useful (e.g., "Task complete")
3. **Manual user tags** via CLI — explicit, highest priority, not overwritten by Claude hooks

### Edge Cases

- **Multiple Claude sessions per workspace**: tags merge from all active sessions
- **Session ends**: tags persist until next session starts or user clears them
- **Tag overflow**: cap at 20 tags; newest replace oldest
- **No Claude session**: tags field is empty, no UI change

## Key Files

| File | Change |
|------|--------|
| `Sources/ContentView.swift` | `CommandPaletteSwitcherSearchMetadata` + indexer + row display |
| `Sources/Workspace.swift` | `searchTags` property + snapshot persistence |
| `Sources/AppDelegate.swift` | `workspace.set_tags` socket command handler |
| `CLI/cmux.swift` | Tag extraction in `claude-hook notification`, `workspace set-tags` CLI |
