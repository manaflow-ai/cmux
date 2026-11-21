# Degenerate lab

Leo, 2026-11-12: "are you guys able to simulate my god-chats? like a true gb-level history sample and stuff, and also
simulate restarts? and simulate fps under load for stuff? and simulate streaming text and acpmux along with lots of
connectivity? like truly degenerated cases/states and seeing where we can identify more perf to tackle". The goal:
"even if a chat is long, there should be no percievable difference" (cmuxterm-hq#9776).

The lab runs the god case and the small case in one harness, idle and loaded, and then once more after the load is
lifted, so it can tell cost that grows with history from noise, and cost that never comes back down.

| File | What |
|---|---|
| `gen_transcript.py` | A seeded Claude Code (or `--format codex`) transcript shaped like Leo's coordinator chat: 272,147 lines and 1.1 GB at `--scale 1`, with sixteen line types at their measured counts and size spreads, MB-sized tool results, images, thinking, and many queue-operation and api-request lines |
| `lab.py` | The matrix: fixtures, the daemon (acpmux `tests/god_daemon.rs` over lane W0's `god_fixture` homes), one god chat restarted, opened and streamed to 32 watchers with one stalled (acpmux `stress::god_chat`), and the chat pane's frames (`webviews/bench/degenerate-chat-frames.bench.ts`), each under `idle`, `cpu` (load 100) or `mem` (pressure into swap), then `recovered` |
| `test_lab.py` | The lab's own tests |

```sh
# Minutes: the harness runs end to end
python3 -I scripts/cmux-next/degenerate-lab/lab.py matrix --preset smoke --out /tmp/lab
# The nightly: 0.1x and 1x; idle, CPU and memory; perf and Chrome traces
python3 -I scripts/cmux-next/degenerate-lab/lab.py matrix --preset nightly --profile --out /tmp/lab
# An hour of fleet load on the daemon, with its heap by allocation site (a dhat-heap build)
python3 -I scripts/cmux-next/degenerate-lab/lab.py daemon --scale 0.1 --load idle --churn 3600 --heap --out /tmp/lab
```

Output: `results.json`, plus `god-small.json` (`{"rows": [{"name", "small_p95", "god_p95"}]}`, which the nightly quality
report reads with `--god-small`; a row fails over 1.2x, as cmuxterm-hq `docs/handbook/perf-regresses-on-degenerate-sessions.md`
says), and `summary.md`.

The nightly is `.github/workflows/cmux-next-degenerate-lab.yml`. It runs on Linux only, never on a person's Mac. The
baseline and the ranked hotspots it found are in cmuxterm-hq `docs/perf/degenerate-lab.md`.

Loads are processes the lab starts in their own process group and stops by that group: stress-ng when it is
installed, otherwise burner processes, and a memory hog that holds all but `--mem-headroom` MB. `perf` runs only where
the kernel allows it (`perf_event_paranoid` at most 1); otherwise the run records why it was skipped and carries on.
