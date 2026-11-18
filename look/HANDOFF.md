# studio: handoff

State: the profile passes the engine; the agent pane (chat and composer) and the New Tab page carry
the look in the web layer; the sidebar is a customize view; PARTS.md has 20 matched, 7 close, 5 gaps.

Next, in order:
1. Merge the kit branch (lane/customize-ui-primitives) once it is pushed and move any web piece
   this look adds onto `webviews/src/kit/index.ts` (today the look adds only CSS and strings).
2. Gallery variants for the changed surfaces (composer placeholder and paperclip, breadcrumb), so
   `scripts/gallery-compare.sh` shows them.
3. Web gaps, each in this branch: the subagents avatar row and "Waiting on N subagents … Stop"
   (`conversation/AgentCallCard.tsx`), and the summary card's editor, worktree, commit rows and
   lineage list (`summary/`).
4. cmux PRs off feat-cmux-next (not here): `branch` in `agent_chat.list`
   (`Packages/macOS/CmuxNext/Sources/CmuxNextApps/Operations/AgentChatSummary.swift`), a sidebar
   header and footer setting (`schemas/settings/source/sidebar.json`).

Tests in webviews/test that pin cmux's own placeholder ("Type / for commands") and New Tab
placeholder fail on this branch by design: the look diverges from them here only.

Captures: `look/captures/*-side.png` (the reference on the left), made in mock mode with the
agent-pane dev server and a black terminal theme.
