# fanin 2026-11-22, fleet Linux pool

`coord-sim fanin` at 50 / 200 / 2,000 sessions over 10 hosts, a 300 s window and one update per session every 3 s (`src/fanin/ci.sh` defaults). The source is feat-cmux-next at ec5f97d1b1e with no code change, so it is the before-row for the fan-out feed fixes. Compare it with `../fanin-2026-11-19-fleet-linux/` (head 9f5c79baeef).

Run: `cmux-ci test --route fleet --setup rust --timeout 7200 -- bash cmux-tui/crates/coord-sim/src/fanin/ci.sh`. The files from that run are added here next to this note.
