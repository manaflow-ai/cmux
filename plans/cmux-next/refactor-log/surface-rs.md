# Refactor log: cmux-tui-core surface.rs lane

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, tests passed, gate and minutes.
Baseline before the lane: surface.rs 10336 lines, 432 fns; incremental `cargo build -p cmux-tui-core` after one edit in surface.rs: 19.6-25.9 s (Testbox tbx_01m4g73kh21de5mytp85cwjjx7).

- 2026-10-09 604a58a094c9, 57aaf3b92d1e: impl Surface browser, mouse, scroll and clear-history methods -> surface/{browser_ops,mouse_input,scrolling,clear_history}.rs; surface.rs 10336 -> 9552; cmux-tui-core tests 2680 passed (unchanged); Testbox fmt + clippy -D warnings + crate tests + windows-gnu --tests, 6 min.
- 2026-10-09 2625dda6c7f1: surface::tests render/geometry, clear-history, stream-progress tests -> surface/tests/{render_geometry,clear_history,stream_progress}.rs (dedent + rustfmt reflow only); surface.rs 9552 -> 8242; #[test] items 2690 before = 2690 after, 2681 passed + 10 ignored; Testbox full gate, 3 min.
- 2026-10-09 bfe371732d09: inline surface::tests -> surface/tests.rs + surface/tests/{lifecycle,input,colors,child_process,byte_mirror,hosted}.rs (dedent + rustfmt reflow only); surface.rs 8242 -> 6188; #[test] items 2690 = 2690, 2681 passed + 10 ignored; Testbox full gate, 3 min.
- 2026-10-09 11f7e904c0ba: impl PtySurface -> surface/pty_surface.rs, color override helpers -> surface/color_overrides.rs, frame producer -> surface/frame_producer.rs, scroll helpers -> surface/scrolling.rs, PTY test doubles -> surface/test_pty.rs; surface.rs 6188 -> 5252; 2690 #[test] items, 2681 passed + 10 ignored; Testbox full gate, 2 min.
