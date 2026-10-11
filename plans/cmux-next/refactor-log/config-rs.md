# Refactor log: lane refactor-config (cmux-tui/crates/cmux-tui/src/config.rs)

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, gates and minutes.
Base 70bb57f3e77c: config.rs has 9,920 lines (383 KB). Incremental `cargo build -p cmux-tui` after one changed
function in config.rs on a warm Testbox: 14.7 / 12.7 / 10.6 s.

## Landings

- 2026-10-09 050fb05af756 refactor-config: config.rs inline tests -> config/tests.rs (helpers) + 10 topic files in config/tests/; test re-exec path, cmux-tui.yml valgrind filters and the workflow security test name the new paths; config.rs 9920 -> 5967; 132 tests before and after; Testbox fmt, clippy, cmux-tui tests 2072 passed, Windows check, about 8 min.
- 2026-10-09 cbc406d5cdbf (push 2f2961230a58) refactor-config: config.rs Ghostty defaults -> config/ghostty_config.rs (885, parse/themes/includes), config/ghostty_helper.rs (resolver child process, 264), config/ghostty_theme_mode.rs (system appearance, 371); private items + 2 methods + 3 fields -> pub(super), pub(crate) re-export of the 2 helper entry points; config.rs 5967 -> 4477; 132 config tests before and after; Testbox fmt, clippy, cmux-tui tests, Windows check, about 5 min.
- 2026-10-09 a0aa1783746f (push 2f2961230a58) refactor-config: config.rs config file I/O (config_path, bounded reads, atomic plugin writes, parent dir sync) -> config/file_io.rs (306); re-exports keep config::{config_path, read_bounded_utf8_file, read_config_text, write_agent_plugin, write_sidebar_plugin}; config.rs 4477 -> 4166; 132 config tests before and after.
- 2026-10-09 4aa9f9142bdf (push c30958c57ced) refactor-config: config.rs Action enum + indexes -> config/action.rs (97), action catalog (definitions, macros, Action helpers) -> config/action_catalog.rs (398), test-only action metadata -> config/action_metadata.rs (519, cfg(test)); check-spec-inventory.py reads config.rs plus config/*.rs; config.rs 4166 -> 3169; 132 config tests before and after.
- 2026-10-09 2c6f73305b48 (push c30958c57ced) refactor-config: config.rs key chords + Keys table -> config/keys.rs (482), load() + user command binding + raw file read -> config/load.rs (776), status bar options + segment resolution -> config/status_bar.rs (140); 3 Keys methods + Keys.bindings -> pub(super); config.rs 3169 -> 1790; 132 config tests before and after.
- 2026-10-09 2668f3e284cd (push e52db77bfbb5, receipt /tmp/gates/2668f3e284cd20c42c8f2771048021a3394a150f.json) refactor-config: config.rs theme + color parsing -> config/theme.rs (380), sidebar config -> config/sidebar.rs (486), machine/provider config -> config/machines.rs (63), tabs -> config/tabs.rs (64), browser -> config/browser.rs (26); ColorValue::to_color -> pub(super); config.rs keeps the raw serde schema and the resolved Config; config.rs 1790 -> 811 (25 KB, godfile baseline entry dropped); 132 config tests before and after.

## Result

config.rs 9,920 lines / 383 KB -> 811 lines / 25 KB. Largest new files: config/ghostty_config.rs 33 KB,
config/load.rs 31 KB, config/tests/ghostty_config_files.rs 29 KB. Incremental `cargo build -p cmux-tui` after
one changed function, same warm Testbox: before 14.7 / 12.7 / 10.6 s (tab_label in config.rs); after
13.8 / 10.2 / 10.4 s (tab_label in config/tabs.rs) and 11.6 / 11.4 / 10.4 s (Config::scrollback_limit_bytes in
config.rs). No measurable gain: cmux-tui is one binary crate, so any edit recompiles and relinks the crate.
A real build-time gain needs config to move into its own crate (phase 2, not move-only).
