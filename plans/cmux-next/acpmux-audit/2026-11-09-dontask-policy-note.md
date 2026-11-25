# Notice to PL-acpmux: the policy note in Claude's dontAsk (2026-11-09)

Follow-up to #39057 (owner W5-S). `question_answer.rs` `app_allow_note`: a Claude chat in
`dontAsk` under a daemon default (not its own policy) asked nothing, and the note said it "asks
before some tools run". It now says that a tool not allowed beforehand is denied, not asked,
that the default does not hold, and how to hold it (`acpmux session set NAME policy=P`);
English and Japanese. The modes are in `web_modes::DENIES_UNASKED_MODES`, keyed by harness
family as `RUNS_EVERYTHING_MODES` is. A chat's own policy keeps the asking note.
Review 3 of #39057, in the same PR: `runs_everything_unasked` holds a reviewed family (claude,
codex, opencode) to its row, and judges any other family (a launcher such as `codex-sr2`,
Gemini, a custom agent) by acpmux's shared full-access rule (`start_mode::is_full_access`,
`spec/full-access-modes.json`), so `codex-sr2` in `agent-full-access` and Gemini's `yolo` get
the bypass note. `mode_family` and the CLI's `mode_family_of_detail` share one rule
(`mode_family_by`); `mode_family`'s result is unchanged, so `policy_mode.rs` is unchanged.
