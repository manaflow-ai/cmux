# OSC 7501 program status: spec conformance matrix

Spec: [Program Status Protocol, revision 0.3 (2026-10-07)](https://www.superlogical.com/rex/docs/build/program-status)
(summary: [mitchellh.com/writing/program-status-osc7501](https://mitchellh.com/writing/program-status-osc7501)).
Bead cx-6so.36.5 (parent cx-6so.36). Daemon contract: `.cmux-scratch/nx-osc7501/CONTRACT.md` (hq).
Audited at feat-cmux-next `c6a0cd6d999c`, ghostty-next pin `3339f2ada`.

Layers: **P** = parser, `ghostty-next/src/terminal/osc/parsers/program_status.zig`
(ported from ghostty-org/ghostty#14560 in manaflow-ai/ghostty-next#29) and its
handler in `src/terminal/stream_terminal.zig`; **B** = Rust binding
`cmux-tui/crates/ghostty-vt/src/terminal/program_status.rs`; **D** = daemon records
`cmux-tui/crates/cmux-tui-core/src/program_status.rs`, published as
`extra.program_status` (`resource_api.rs`, `mux/terminal_progress.rs`,
`surface/directory.rs`); **S** = Swift mirror and UI (`CmuxNextDaemon/State/ProgramStatusRecord.swift`,
`CmuxNextBridge/StatusMapping.swift`, `TabItemMapping.swift`, `ProgramStatusSeen.swift`,
`CmuxNextApp/Notifications/*`).

Verdicts: **yes** conforms; **fixed** conformed only after this bead; **gap** open;
**n/a** a MAY the product does not take.

## Syntax and parsing

| Spec rule | Verdict | Where / evidence |
| --- | --- | --- |
| `OSC 7501 ; pairs ST`, ST is `ESC \` or BEL | yes | P `parse` (terminator independent); live `bel` step |
| pairs `:`-separated, `key=[a-z]+`, value set `[A-Za-z0-9_.,+/=-]*`, whitespace trimmed | yes | P `lastValue`/`value_bytes`; test "whitespace around keys and values" |
| malformed pair skipped, rest processed | yes | P test "malformed pairs and unknown keys are skipped" |
| unknown keys MUST be ignored | yes | same test (`future=yes`) |
| repeated key: last wins | yes | P test "last value wins" |
| `msg`/`title` base64 UTF-8, padding optional | yes | P `decodeText`; test "base64 padding is optional" |
| decoded text with C0/DEL/C1 control char discards the whole report | yes | P `encoding.isSafeUtf8`; test "text must decode to safe UTF-8"; live `discarded` |
| bad base64 discards the whole report | yes | same test; live `discarded` |
| over any limit discards the whole report; check every pair before touching a record | yes | P `validate` runs before the command is returned; test "discarded reports" |
| missing/unknown `state` ignores the report | yes | P `validate` `InvalidState`; live `discarded` (`state=sleeping`) |

## Limits

| Limit | Verdict | Where |
| --- | --- | --- |
| sequence 4096 bytes | yes (BEL-terminated: 1 byte stricter, allowed by "MAY choose lower limits") | P `max_body_bytes` |
| key 16 bytes (unknown keys too) | yes | P `validate` first loop |
| msg 2732 encoded / 2048 decoded, encoded checked before decoding | yes | P `max_msg_*`; live `discarded` (3680-byte msg) |
| title 256 / 192 | yes | P `max_title_*` |
| app 32 | yes | P |
| id 128 total, 32 per segment, 8 levels | yes | P `validateId`; test "ids" |
| records per terminal 256 (>= 64), evict least recently updated | yes | D `MAX_RECORDS`, eviction by `updated_seq`; test `the_record_updated_longest_ago_goes_first_at_the_limit` |
| shown text lower caps (title 256 chars, msg 1024 chars) | yes ("MAY shorten") | D `shown_text` |

## Records, ids, states, lifetime

| Spec rule | Verdict | Where / evidence |
| --- | --- | --- |
| no id = root record | yes | B `id` empty; D key `""` |
| invalid id ignores the report (never falls back to root) | yes | P `validateId` returns null; live `discarded` (`id=a//b`) |
| each report replaces its record completely | yes | D `apply_report`; test `a_report_replaces_its_record_completely` |
| `/` hierarchy: clear removes the record and its descendants | yes | D `clear` prefix retain; test `clear_removes_a_record_and_its_descendants_only`; live `hierarchical-clear` |
| clear with no id removes every record | yes | D; live `rsync-cleared` |
| **app inheritance from the nearest ancestor (MUST)** | **fixed** | D `app_of`, published `app` is inherited; red `afa070cae194`, fix `fe521fcac6c6`; test `a_record_without_app_takes_the_nearest_ancestors_app`; live `deploy-app-inherited` |
| parent need not exist | yes | D `app_of` walks missing ancestors; same test (`eu/west/pod`) |
| root and child records coexist | yes | live `deploy-three-records` |
| screen switch (alt screen) has no effect | yes | records live in D, not on a screen |
| RIS removes every record; DECSTR does not | yes | P handler reports `clear` on full reset (stream_terminal.zig `fullReset` path); D clear |
| `kind` only with blocked; unknown kind = absent | yes | P `readOption(.kind)`; D `kind.filter(blocked)`; test `kind_and_progress_only_stay_on_the_states_that_carry_them` |
| `progress` 0-100 only with working/blocked; absent = indeterminate; else absent | yes | P `parseProgress`; D filter; S draws indeterminate when nil (`StatusMapping.state`) |
| `app` outside its charset = absent | yes | P `isName` |
| no heartbeat required | yes | D keeps records until an event |
| process exit drops working/blocked (MAY idle) | yes | D `to_json(running: false)` hides transient; test `an_exited_terminal_shows_only_done_and_error` |
| OSC 133 A drops working/blocked (MAY idle) | yes | B `semantic_prompt_trampoline` (primary prompts); D `end_transient`; test `prompt_start_ends_...`; live `terraform` then prompt |
| done/error survive exit and prompt; terminal decides when to stop showing | yes | D keeps them; S `ProgramStatusSeenStore` hides seen ones (focus/typing); live `rsync-done-after-prompt` |

## Feature detection and terminfo

| Spec rule | Verdict | Where / evidence |
| --- | --- | --- |
| `OSC 7501 ; ?` answered with the same body, same terminator | yes | P handler `.query` (only when a program_status effect is set); terminal host answers once (`host_parser.rs` `query_only_sink`, mirror `on_pty_write: None`); live `query-st`, `query-bel` |
| only fixed bytes written back, records unreadable by the program | yes | P handler writes `\x1b]7501;?` + ST only |
| **terminfo `Pst=\E]7501;%p1%s\E\\` (SHOULD)** | **fixed** | shipped overlay `Resources/terminfo-overlay/{78/xterm-ghostty,67/ghostty}` and base `Resources/ghostty/terminfo`; red `29e6b0d17b75`, fix `3329dc33c0a2`; `scripts/cmux-next/tests/bundled-terminfo.test.sh`; live `terminfo-pst` |
| XTGETTCAP `Pst` (same table) | **fixed in fork, pin pending** | manaflow-ai/ghostty-next#32 (red `8754b730a`, green `97f843dd9`, test "XTGETTCAP responses"); needs the ghostty-next pin bump (CORE window); live `xtgettcap-pst` stays a gap until then |

## Display, notifications, security

| Spec rule / contract row | Verdict | Where / evidence |
| --- | --- | --- |
| never markup; plain text only | yes | S shows `title` only as a `StatusReport.label`; banners are plain `UNNotificationContent` text |
| disarm bidi/invisible formatting outside the grid (SHOULD) | yes | D `shown_text` strips Cf controls; test `shown_text_drops_invisible_formatting_and_caps_length`; live `bidi` |
| `msg`: MUST NOT read meaning into it | yes | no code branches on `msg` |
| tab indicator: working (progress), blocked = attention dot, error/done = unseen badge | yes | S `StatusMapping.reports/needsInput/outcome`, `TabItemMapping.status`; tests `ProgramStatusSeenTests`; live snapshots |
| workspace row working/attention | yes | S `WorkspaceRowContent` (`showsWorking`), `StatusMapping.summary(tabs:)` |
| **blocked -> notification worded by kind; error -> notification (contract)** | **fixed** | D `raise_alert` -> `TerminalMetadata::admit_program_status_alerts` -> `Mux::post_terminal_notifications` (Warning/Error, source `terminal`, on the record's surface); red `afa070cae194`, fix `fe521fcac6c6`; test `blocked_and_error_records_post_one_terminal_notification_each`; live `terraform`, `rsync-error`, `deploy-three-records` |
| rate-limit external effects (SHOULD) | **fixed** | the same per-terminal gate as OSC 9/777/99 (1 s spacing, 5 s for repeated text); a repeated blocked report (progress update) posts nothing |
| **say which terminal a shown record came from (SHOULD)** | **fixed** | tab/row indicators sit on the source tab; banners from `terminal` sources carry the workspace name as subtitle (`NotificationCenterService.bannerSubtitle`); red `67611c6d3c89`, fix (this branch); test `aTerminalProgramsBannerNamesItsWorkspace`; `debug.notifications` shows `subtitle` |
| notifications follow the user's terminal-notification setting | yes | source `terminal` (`desktop-notifications = false` silences them, `NotificationCenterService.arrived`) |
| OSC 9;4 mapping to the root record | n/a | cmux keeps OSC 9;4 as its own `extra.progress`, so the "stop mapping after 7501" rule never applies |

## cmux surfaces

| Surface | Verdict | Where / evidence |
| --- | --- | --- |
| CLI `cmux terminal <sel> status [--json]`, MCP `terminal_get` | yes | `cmux-tui/crates/cmux-tui/src/cli/command/plan.rs`; live script reads every step through it |
| session events / snapshot `extra.program_status` | yes | test `program_status_osc7501_reaches_snapshot_and_event_feed` |
| cmux TUI | partial | blocked/error now raise a tab/sidebar unread dot through the notification ledger (severity color); the TUI draws no working spinner or progress for any source yet (OSC 9;4 neither); live `tui` |
| daemon restart | gap | records are lost; the terminal host keeps none and the mirror is rebuilt from a screen snapshot, so the next report restores them. Fix needs the host to keep records and a host protocol field (CORE + terminal-host protocol). |
| nested multiplexers (tmux, nested cmux, ssh) | yes for ssh; documented for the rest | ssh is transparent. A program inside tmux needs tmux passthrough (`allow-passthrough on` + DCS wrapping, the program's choice). A program inside a nested cmux reports to the inner terminal, whose daemon keeps the records; the outer cmux sees nothing, as the spec's "per pseudo-terminal" model says. |

## Left open, with reasons

1. XTGETTCAP `Pst`: merged only once manaflow-ai/ghostty-next#32 lands and the pin moves (CORE window, rebuild of libghostty-vt and GhosttyKit).
2. Daemon restart loses records (see table). Programs restore them with their next report; no data is wrong, only missing.
3. The TUI has no working/progress indicator for any status source; adding one is a TUI feature, not a protocol rule.
4. Notification wording comes from the daemon in English, like the agent-hook notifications ("Claude needs approval"); localizing daemon notification titles is a separate change for both producers.
5. `msg` is not shown anywhere except the notification body (no hover detail exists for any status source yet).
