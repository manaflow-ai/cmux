# fanin 2026-11-27, fleet Linux pool

`coord-sim fanin` at 50 / 200 / 2,000 sessions over 10 hosts, a 300 s window and one update per session every 3 s (`src/fanin/ci.sh` defaults). The source is feat-cmux-next at 7d8af523c63 with no code change. It is the after-row for the four per-prompt cuts merged since the 2026-11-24 receipt (b95df12d1f25, worst ratio fan-out p95 4.65x): cmux#57952 (9af0c608, fan-in burst tail), cmux#57002 (f4dc66b, host ms per prompt), cmux#57984 (be24b4dc, meta_save) and cmux#57985 (1037e1cb, secret_scan once per prompt).

Run: `cmux-ci test --route fleet --setup rust --timeout 7200 -- bash cmux-tui/crates/coord-sim/src/fanin/ci.sh`. The run's summary is added here next to this note.
