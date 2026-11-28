# Check templates: the minimal rigorous check per kind of change

Leo, 2026-11-27: "add in whatever minimally rigorous things to be proving correctness and perf in fast fail open
ways/targetted tests per type of situation that things touch based off relevance."

`scripts/bench/cmux-bench for-paths FILE...` names the template for each situation a change touches
(`docs/benches/relevance-map.toml`, `[[situation]]`). Each page says what the check proves, the smallest test
that proves it, a code skeleton, and the cmux test that already does it, to copy from.

| situation | the check | copy from |
|---|---|---|
| [main-thread](main-thread.md) | a budgeted bench at Leo/Lawrence scale, flat when the input grows 10x | `AcpmuxChatRowsBench` |
| [bridge](bridge.md) | bytes and calls per frame across Swift↔Rust, budgeted | `ChiefFaceFlushBenchTests` |
| [protocol](protocol.md) | one contract fixture both sides decode and encode | `cmux-pane-protocol` codegen + webviews `src/protocol` |
| [persisted-format](persisted-format.md) | golden round-trip + an old build's file read by the new reader | `persisted-formats/formats.toml` (`migrate` policy) |
| [migration](migration.md) | model-based: old->new on random states, against the old code as oracle | `tests/test_bench_relevance_map.py` (index vs scan) |
| [visible-ui](visible-ui.md) | a gallery snapshot of every state the change can show | `webviews/src/gallery` |

Fail open: a template is advice the PR's author or agent follows; for-paths never blocks on one. What blocks is
the check once written: a budget past its number, a fixture that no longer reads, a contract that drifted.
