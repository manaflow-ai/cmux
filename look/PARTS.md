# studio: parts

The reference app (dark), part by part. `matched` looks and works as the reference does;
`close` is there with a visible difference; `gap` names what is missing and where it would go.
Captures: `captures/chat-side.png`, `captures/newtab-side.png`, `captures/summary-side.png` (Lineage), `captures/sidebar-render.txt`.

| Part | State | Notes |
|---|---|---|
| Sidebar header (app name, collapse) | gap: native title bar | The sidebar's top row is Swift chrome; no setting puts the app name and a collapse glyph there. A cmux PR: a `sidebar.header` setting in `schemas/settings/source/sidebar.json`. |
| Search row with filter, new-folder and new-chat icons | matched | `customize/main.js`: Search field, filter (needs you or working), Open Folder (`openFolder`), New Chat (`new.agentChat`). |
| Project folders (chip per chat) | matched | Two-letter tinted project chip on each chat's first line, as the reference. |
| Chat row line 1: project and time | matched | Project name, then the age (7m, 2h) or a status (Working, Done, Input, Failed). |
| Chat row line 2: bold title | matched | 14px medium, one line, truncated. |
| Chat row line 3: branch and provider glyph | close | The agent glyph is at the line's end. The branch shows only when `agent_chat.list` reports one; today it doesn't, so the line falls back to what the chat does now. Gap: `branch` in `Packages/macOS/CmuxNext/Sources/CmuxNextApps/Operations/AgentChatSummary.swift` `appJSON`. |
| Selected row | matched | The host's `selected` fill with an 8px corner. |
| "Working" and "Settled N" shelves at the bottom | matched | Both closed by default, the count on the right with a chevron, each keeping the open chat visible. |
| Account row (settings, git, stats icons) | gap: native sidebar footer | Swift chrome; a cmux PR would add a `sidebar.footerButtons` setting. |
| Chat title bar: "project / chat title" | matched | `header/ThreadTitle.tsx`: the project, muted, a slash, then the title. |
| Right-side panel toggles | close | cmux's header tools (outline, inbox, terminal, browser, more) sit where the reference has its three panel toggles; same place and weight, different set. |
| User prompt: right-aligned dark pill | matched | `#1a1a1a`, opaque, 1rem corner. |
| Assistant text | matched | `#f1f3f7` on black, system font / Inter. |
| Inline code | matched | White 8% fill, ui-monospace / SF Mono. |
| Code blocks | matched | 0.5rem corner, white 3% fill on the 8% hairline. |
| Tool rows | close | cmux groups tool calls into one muted row ("Ran a search, ran a command…") the reference does not show in this shot; color and weight match its muted lines. |
| "Worked for 20s ›" | matched | Muted, the chevron after it, a hairline under it. |
| Subagents row (avatars, "N subagents", "N working") | matched | `subagents/SubagentGroup.tsx`: the avatar stack, "4 subagents" bold, then "4 working" in the primary colour, the time and a chevron. One line, not the reference's two, so the row keeps its measured height. |
| "Waiting on N subagents … Stop" | close | `subagents/SubagentTray.tsx`: the running tray folded over subagents reads "Waiting on 4 subagents" and their names, muted. Stop is the tray's per-agent stop and the composer's, not a word at the line's end. |
| Scroll-to-bottom button | matched | Round, on the black page. |
| Composer box | matched | Near-black card, white 8% hairline, 1rem corner, the reference's `0 14px 32px -18px` shadow. |
| Placeholder "Ask anything. @ files, $ skills, / commands" | matched | `Composer.tsx` via `look/studio.ts`. |
| Attach button bottom-left | matched | Paperclip (`ComposerPlusMenu.tsx`); it opens cmux's attach menu. |
| Model picker ("Opus 5.5 High") bottom-right | matched | The model with its effort, beside send. |
| Effort | matched | Shown with the model, as the reference ("High"). |
| Send button (round) | matched | Round, white 10% at rest, filled off-white when ready. |
| Row below the composer | close | The reference has none; cmux keeps its permission mode chip in the composer foot when a mode is set. Mic and context ring are hidden. |
| Right-side panel (editor, worktree, branch, commit, changes rows) | close | The summary card is the reference's floating card. It has the machine, Open in editor (`session-info/EnvironmentSection.tsx`, it opens the project folder), branch and Changes +/- rows. Setup Worktree and Commit have no pane action to run, so they are left out rather than drawn dead. |
| Lineage list | matched | `summary/SubagentStatusList.tsx`: "Lineage · 4 running" over a row per agent with its mark and time. |
| Empty chat | close | Black page with the composer at the bottom; the reference shows no empty state either. |
| New Tab page | matched | `tabs.newTabTemplate: minimal`: the composer card alone, with the studio placeholder and the paperclip. The reference has no New Tab page; this is its composer. |
| Settings page | close | Inherits the theme file (black, hairlines, indigo accent); its layout is cmux's. |

Matched: 22. Close: 8. Gap: 2.
