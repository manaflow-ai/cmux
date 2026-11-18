# studio: handoff

State: the profile passes the engine; the agent pane (chat and composer) and the New Tab page carry
the look in the web layer; the sidebar is a customize view; PARTS.md has 20 matched, 7 close, 5 gaps.

Done since the first handoff: the subagent batch line ("4 subagents · 4 working"), the running
tray's "Waiting on N subagents" head, the summary card's Open in editor row and Lineage title, a
gallery entry (`webviews/src/look/studio.gallery.ts`, id `look.studio`, variants chat and
new-tab), and the kit branch (lane/customize-ui-primitives) merged in. No new component was
written: the rows reuse the pane's own (EnvironmentSection's Row, SubagentGroup, the tray).

Next:
1. Setup Worktree and Commit rows in the summary card need pane actions to run (none exist);
   Stop as a word at the end of the waiting line needs the tray to stop every subagent at once.
2. cmux PRs off feat-cmux-next (the sidebar gap lane has them): `branch` in `agent_chat.list`,
   sidebar header and footer settings.

Tests in webviews/test that pin cmux's own placeholder ("Type / for commands") and New Tab
placeholder fail on this branch by design: the look diverges from them here only.

Captures: `look/captures/*-side.png` (the reference on the left), made in mock mode with the
agent-pane dev server and a black terminal theme.
