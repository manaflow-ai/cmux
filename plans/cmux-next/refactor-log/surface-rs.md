# Refactor log: cmux-tui-core surface.rs lane

Append-only. One line per landing: date, SHA, what moved where, old -> new lines, tests passed, gate and minutes.
Baseline before the lane: surface.rs 10336 lines, 432 fns; incremental `cargo build -p cmux-tui-core` after one edit in surface.rs: 19.6-25.9 s (Testbox tbx_01m4g73kh21de5mytp85cwjjx7).

- 2026-10-09 604a58a094c9, 57aaf3b92d1e: impl Surface browser, mouse, scroll and clear-history methods -> surface/{browser_ops,mouse_input,scrolling,clear_history}.rs; surface.rs 10336 -> 9552; cmux-tui-core tests 2680 passed (unchanged); Testbox fmt + clippy -D warnings + crate tests + windows-gnu --tests, 6 min.
