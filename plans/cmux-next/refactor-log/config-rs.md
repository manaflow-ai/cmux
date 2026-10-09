# Refactor log: lane refactor-config (cmux-tui/crates/cmux-tui/src/config.rs)

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, gates and minutes.
Base 70bb57f3e77c: config.rs has 9,920 lines (383 KB). Incremental `cargo build -p cmux-tui` after one changed
function in config.rs on a warm Testbox: 14.7 / 12.7 / 10.6 s.

## Landings

- 2026-10-09 050fb05af756 refactor-config: config.rs inline tests -> config/tests.rs (helpers) + 10 topic files in config/tests/; test re-exec path, cmux-tui.yml valgrind filters and the workflow security test name the new paths; config.rs 9920 -> 5967; 132 tests before and after; Testbox fmt, clippy, cmux-tui tests 2072 passed, Windows check, about 8 min.
- 2026-10-09 L2 refactor-config: config.rs Ghostty defaults -> config/ghostty_config.rs (885, parse/themes/includes), config/ghostty_helper.rs (resolver child process, 264), config/ghostty_theme_mode.rs (system appearance, 371); private items + 2 methods + 3 fields -> pub(super), pub(crate) re-export of the 2 helper entry points; config.rs 5967 -> 4477; 132 config tests before and after; Testbox fmt, clippy, cmux-tui tests, Windows check, about 5 min.
