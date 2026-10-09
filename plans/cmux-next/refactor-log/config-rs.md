# Refactor log: lane refactor-config (cmux-tui/crates/cmux-tui/src/config.rs)

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, gates and minutes.
Base 70bb57f3e77c: config.rs has 9,920 lines (383 KB). Incremental `cargo build -p cmux-tui` after one changed
function in config.rs on a warm Testbox: 14.7 / 12.7 / 10.6 s.

## Landings

- 2026-10-09 (this commit) refactor-config: config.rs inline tests -> config/tests.rs (helpers) + 10 topic files in config/tests/; config.rs 9920 -> 5967.
