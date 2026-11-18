# Handoff: the Claude Code desktop look

State at this head: the profile passes `customize use` / `customize check` / `theme check` in a temp
HOME; the web layer typechecks (`bun run typecheck` on the fleet's Linux pool); PARTS.md is
complete (13 matched, 15 close, 4 gap); `captures/` holds the mock-pane captures beside the reference.

## Open
- **Real-app capture.** Not taken yet: it builds the pushed head on the fleet, then queues on a
  display worker. Steps file: write the profile into a terminal, `cmux customize use` + `apply`,
  open the native fixture chat and a new chat (see the parent's capture-route brief). Put the
  side-by-side in `captures/` and update PARTS.md's native rows (sidebar, title bar, Sessions section).
- **Tests this branch disagrees with on purpose** (they pin cmux's own look): the Write/Edit row
  wording (`test/agent-pane-write-row-label.test.tsx`, `test/claude-code-tool-rows.test.tsx`),
  run folding (`test/transcript-consolidated-runs.test.tsx`, `test/transcript-collapsed-tool-runs.test.tsx`),
  the edited-files card default, the composer look and New Tab template defaults.
- **Branch bar counts** come from the composer's loaded rows (`diff.ts turnFiles`); a whole-branch
  diffstat and the base branch need acpmux to report them (a cmux PR off feat-cmux-next).
- **"Updated todos N items"**: cmux draws the plan card; a one-line collapsible would be a
  PlanList variant in this branch.
- **Live line capture**: the mock delivers a recorded turn at once and its own turn in about 3 s, so
  `look-capture.mjs` doesn't catch the live line yet; the clay asterisk is in `claudeLook.css`.
- **Kit**: nothing here uses webviews/src/kit yet (only ui/ and acpmux icons); merge
  lane/customize-ui-primitives when a piece is needed.
