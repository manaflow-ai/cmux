# cmux-tui aggregate change log

Snapshot: 2026-08-23. Aggregate branch: `aggregate-final`, currently at [`80d5a5393c`](https://github.com/manaflow-ai/cmux/commit/80d5a5393cc5654d00d254adc9c9b78c4e1573df). The branch is 387 commits ahead of and 8 commits behind `origin/main` (counts from `git rev-list`); it must be rebased or merged before landing. The current checkout is a detached documentation worktree at `0faff0e9db`.

Meaningful aggregate changes since the prior audit:

| Commit | Change | Verification / residual | Revert |
| --- | --- | --- | --- |
| [`efbe0bcceb`](https://github.com/manaflow-ai/cmux/commit/efbe0bcceb) | Reject invalid relay configuration before use. | Focused Rust checks are hosted-only; malformed-config callers now fail closed. | `git revert efbe0bcceb` |
| [`836ec27806`](https://github.com/manaflow-ai/cmux/commit/836ec27806) | Bound websocket ingress before allocation. | Hosted Rust verification required; oversized frames are rejected. | `git revert 836ec27806` |
| [`a44378f1d8`](https://github.com/manaflow-ai/cmux/commit/a44378f1d8) | Cap and validate persisted relay configuration. | Diff and static checks; migration risk for over-capacity stored config. | `git revert a44378f1d8` |
| [`7a1816acf6`](https://github.com/manaflow-ai/cmux/commit/7a1816acf6) | Bound relay PTY input frames. | Hosted relay tests required; excess input is rejected. | `git revert 7a1816acf6` |
| [`d1277ff2b5`](https://github.com/manaflow-ai/cmux/commit/d1277ff2b5) | Fail closed on mandatory relay queue overflow. | Hosted behavior proof required; clients must handle explicit closure. | `git revert d1277ff2b5` |
| [`70ac436947`](https://github.com/manaflow-ai/cmux/commit/70ac436947) | Bound preview-proxy websocket queues. | Hosted integration coverage required; slow consumers can be disconnected. | `git revert 70ac436947` |
| [`30419a1ad9`](https://github.com/manaflow-ai/cmux/commit/30419a1ad9) | Bound remote stream chunk queues. | Hosted integration coverage required; queue pressure is now visible as failure. | `git revert 30419a1ad9` |
| [`33c5804900`](https://github.com/manaflow-ai/cmux/commit/33c5804900) | Bound websocket writes and cancel replaced peers. | Hosted relay checks required; replacement closes the old peer. | `git revert 33c5804900` |
| [`80d5a5393c`](https://github.com/manaflow-ai/cmux/commit/80d5a5393cc5654d00d254adc9c9b78c4e1573df) | Validate relay frame protocol bounds at the aggregate tip. | Static checks only in this snapshot; hosted exact-head run remains required. | `git revert 80d5a5393c` |

Known residuals: no claim is made for local Rust test execution, full end-to-end relay coverage, journal/WAL latency, deterministic shutdown of every admitted task, or complete cloud-TUI acceptance. These remain open until an exact pushed SHA has hosted evidence.

Session-count honesty: the accompanying board records at least 180 substantive agent turns for this run. The requested 10,000-session target was not reached, and no empty sessions were created to inflate the count.

