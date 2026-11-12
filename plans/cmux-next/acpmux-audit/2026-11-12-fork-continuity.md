# Fork continuity

PR #41507: remove the Continue In review and show model switches in the same pane.
A fork's inherited transcript now includes `forked` records, so a second switch
keeps the earlier divider through replay and materialization. The history view
still references its parent; no transcript-wide copy or new scan was added.
The existing `rehydrate_note` briefing remains the source for the agent's first
prompt after a switch. The row comparator observes the divider's label and tab
target even when its transcript event version is unchanged.

Regression coverage: `fork_retarget_tests`,
`successive_forks_keep_switch_boundaries_after_replay_and_materialization`, and
`conversation/forkDivider.test.ts`.
