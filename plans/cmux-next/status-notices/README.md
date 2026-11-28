# Every status and error notice in cmux NEXT, with a verdict

Leo, 2026-11-22: "i see in the sidebar a repair connection to agent service... which i have requested to remove a
while ago. or some similar message to it a while ago. we dont need it. ever. entire classes of bullshit fucking
error/status bullshit. fuck em. remove them all."

The rule each row is judged by: a state the person can do nothing about shows nothing until it has lasted the
shared bound (10 s, `schemas/notice-timing/notice-timing.json`); a notice shows at once only with the one button
that fixes it. `scripts/cmux-next/check-connection-notices.py` holds new code to it.

This is the read of `feat-cmux-next` on 2026-11-22: 384 notices on four surfaces.

| File | Surface | Rows | KEEP | DELETE | GATE | FIX-CAUSE |
| --- | --- | --- | --- | --- | --- | --- |
| [mac.tsv](mac.tsv) | Mac app (`Packages/macOS/CmuxNext`) | 133 | 52 | 47 | 31 | 3 |
| [web.tsv](web.tsv) | Web pages (`webviews/src`) | 112 | 40 | 37 | 35 | 0 |
| [rust.tsv](rust.tsv) | Rust that decides or words a notice (`cmux-tui/crates`) | 70 | 14 | 31 | 12 | 13 |
| [ios.tsv](ios.tsv) | iPhone app (`cmux-next-ios`, `Packages/iOS`) | 69 | 40 | 15 | 14 | 0 |

## Columns

`surface`, `file:line`, `key_or_unit`, `english_text`, `trigger` (what makes it show and how often), `action` (what
the person can do from it), `bound` (how long the state must last before it shows), `class`, `verdict`, `reason`.

## Verdicts

- **KEEP**: the person asked for it or must act, and the notice carries the action. The `reason` column is its
  justification.
- **DELETE**: the state heals by itself and nothing on screen changes it. Remove the words.
- **GATE**: worth saying only once it has lasted the shared bound, and then with its action.
- **FIX-CAUSE**: the notice is honest but the state is too frequent or declared too early; fix what produces it.

## Causes behind the frequent states

- Health policy calls a part slow at 3 to 5 s, under the 10 s bound (`cmux-health-core/src/policy.rs`).
- The agent service is called stuck at 10 s, with no allowance for a wake or an update.
- Heartbeat misses on wake count as a lost link (`cmux-daemon-conn-core/src/heartbeat.rs`).
- A peer link is degraded after one missed 2 s ping.
- Every app update hands the owner over, which each surface drew as a reconnect (`handoff.rs`).
- Status reads block on the hub (`acpmux/src/hub/views.rs`).

## Keeping it true

A row's file and line were right on the date above and drift after. When a change deletes or gates a notice, delete
its row or change its verdict to KEEP with the new reason in the same change. A new notice gets a row.
