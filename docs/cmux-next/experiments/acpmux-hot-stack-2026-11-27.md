# acpmux hot stack under load (2026-11-27)

One `sample PID 5` of the acpmux daemon on an attended dev Mac at load average
100 to 250, NIGHTLY commit `946de8b`, while acpmux deliveries were stalling.
Symbolized against the unstripped `cmux-tui-aarch64-apple-darwin` artifact
from that commit's "cmux-tui artifacts" run (UUID
`4C4C443C-5555-3144-A1A8-2DD7D7D48296` matches the shipped binary) with
`scripts/perf/symbolize-sample.py`. `atos` against the same binary returned
bare addresses.

231 threads. 8,879 on-CPU samples in 5 s (about 12 threads busy the whole
window); 6,674 samples are 9 threads parked in `flock` for the full sample.

## Where the CPU goes (inclusive, own frames)

| samples | frame |
|--:|---|
| 2,606 | `server::fanout::send_event` -> `deliver_once` -> `server::delivery::deliver` |
| 1,153 | `Hub::warm_round` closure |
| 907 | `peer_snapshot::warm::Hub::peer_rows` -> `PeerRow::value` (881) |
| 789 | `server::Conn::send_as` |
| 739 | `transfer_history::Hub::write_lines` -> `JournalStore::scan` -> `LocalStore::scan_lines`, serializing `EventRecord` (one thread, all 5 s) |
| 671 | `server::session_patch::send_row` (diff 224, hash_of 183, shape_of 184) |
| 619 | `Hub::summary_with_tools` -> `row_inputs` (546) |
| 541 | `hub::bg_tasks::bg_gone` -> `agent_host::liveness_of` (492, opening files via `home_fs::unix::open`) |
| 454 | `Hub::bg_list_as`; `bg_running_count` 362; `bg_running_pids` 232 |
| 361 | `server::Conn::send_reply` |
| 176 | `Hub::save_peer_cache_now` |

Leaf work under these: `File::write` (820), BTreeMap clone and drop
(`clone_subtree` 329, `IntoIter::drop` 288, `find_key_index` 432),
`serde_json` escape and `Value::clone`, `Vec` allocation, `openat`.

## Reading

- Delivery serializes and writes each event per subscriber
  (`deliver` -> `send_as` -> `Line::serialize` -> `File::write`): fan-out cost
  grows with subscribers times event size. Serialize once per event.
- `peer_rows` / `PeerRow::value` rebuild every peer row as a `serde_json::Value`
  each warm round, cloning BTreeMaps. Cache the rendered row and rebuild on change.
- `bg_gone` calls `liveness_of` for each background task on every
  `bg_list` / `bg_running_count`, opening files each time. Cache liveness per
  pid for the round.
- `write_lines` scans the whole journal for one history transfer and held one
  thread for the whole sample.
- The 9 `flock` threads call `flock` straight from the thread closure; check
  they are lock holders, not workers queued on one lock.

## Reproduce

```
sample "$(pgrep -f 'bin/acpmux daemon' | head -1)" 5 -file /tmp/acpmux.sample.txt
gh run download <cmux-tui artifacts run for the NIGHTLY commit> -n cmux-tui-aarch64-apple-darwin -D /tmp/tui
dwarfdump --uuid "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux" /tmp/tui/cmux-tui-aarch64-apple-darwin
scripts/perf/symbolize-sample.py /tmp/acpmux.sample.txt /tmp/tui/cmux-tui-aarch64-apple-darwin /tmp/acpmux.sym.txt
```
