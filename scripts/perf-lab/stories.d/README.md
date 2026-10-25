# Perf lab stories

One JSON file per story: `stories.d/<id>.json` (plans/cmux-next/chrome-parity/p12-perf-process.md, rule R7).
Each story names one build config (rule R6). The series key includes the config, so results from two
configs are never in the same series.

## Build configs

Each config is a `scripts/reload.sh --config <name>` build. A tagged app records its config in
`Info.plist` as `CMUXBuildConfig`. Anything that caches a built app or a result keys it on
(sha, config).

| Config | Flags | Use it for |
| --- | --- | --- |
| `bench` | Release optimization + `-DCMUX_BENCH_HOOKS` (no DEBUG) | Latency, frame, launch, idle and memory stories. This is the default for a story. |
| `bench-checks` | `bench` + `-DCMUX_BLOCKING_CHECKS` | Only the blocking-sites story (`blocking-hangs`). The detector records each main-thread blocking call for `debug.blocking`. |
| `release` | The shipped Release flags | The parity story (bench against Release on `action.commit`) and the shipped-Nightly story. |

Rules:

- Do not measure latency, frames, launch, idle or memory on `bench-checks`. The blocking detector
  does bookkeeping on each checked call and each `Mutex` lock, so its numbers are not the shipped
  app's numbers.
- Do not compare Debug results with bench results.
- `scripts/cmux-next/check-no-bench-hooks.sh --expect <app>` passes for `bench` and `bench-checks`
  builds. Without `--expect` it refuses both, so neither can ship.
- The executable of a `bench` build and a `bench-checks` build carry the same bench-hooks marker.
  Read `CMUXBuildConfig`, or state the config (`bench_launch.BenchApp(build_config=...)`), to tell
  them apart.
