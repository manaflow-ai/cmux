# mobile-bench: our iPhone app next to Claude, Codex and other chat apps, frame by frame

One command answers "is this flow as fast and smooth as theirs?":

```sh
scripts/mobile-bench/compare-mobile keyboard-show          # our pushed HEAD vs the references
scripts/mobile-bench/compare-mobile all --ref <sha>        # every flow at a commit
scripts/mobile-bench/compare-mobile --list                 # the flow ids
```

It captures our app on a fleet iOS simulator (one `cmux-ci run --class simulator` step running
`MobileBenchFlowsUITests` with the screen recorded), cuts one clip per flow, measures every clip,
and prints a table per flow with the competitors' rows from cmux-design-references
(`apps/<app>-mobile/bench/<flow>/`). Nothing builds on the machine you run it from. The skill
[skills/compare-mobile](../../skills/compare-mobile/SKILL.md) is the how-to for agents.

| File | What it does |
|---|---|
| `flows.json` | The 16 flows: stimulus, what counts as the response, when it has settled, the screen region, the moving edge |
| `measure.py CLIP_DIR` | Measures one clip: response, settle and motion times, dropped frames, worst frame gap, layout jumps, pop-in bursts, the fitted spring |
| `cut.py REC MARKERS OUT --app A` | Cuts one long recording into per-flow clips by its `MOBILEBENCH` marker lines |
| `table.py DIR...` | Side-by-side Markdown tables from measured clips |
| `compare-mobile FLOW` | All of the above, with the capture |
| `../measure/ios_rotate.py` | The `rotate` flow from the app's own frames: RotateBenchUITests' trace, marks and main-thread log, per surface and duress run (response, settle, our main thread's longest iteration per turn) |
| `../measure/ios_snappy.py` | snappy-bench/v1 from the app's own frames (SnappySendBenchUITests, `CMUX_MOBILE_SEND_TRACE`): send to the user row's paint, reserved row in the same frame, send to first token, layout shifts per send, chat switch to paint; local, mock-link cloud and a 1000-turn chat |
| `test_measure.py` | Synthetic clips with known springs, delays and drops; `python3 scripts/mobile-bench/test_measure.py` |

Only Python's standard library and ffmpeg are needed (PATH, `$MOBILE_BENCH_FFMPEG`, or
imageio-ffmpeg's bundled binary).

## Clip contract

A clip is a folder with `clip.mp4` and `meta.json`:

```json
{"app": "Claude", "flow": "keyboard-show", "source": "mac-iphone-app", "device": "Mac mini M4 Pro, 120 Hz virtual display",
 "os": "26.1", "app_version": "1.2025.330", "build": null, "recorded_at": "2026-11-19T12:00:00+00:00",
 "stimulus_t": 0.5, "fps_nominal": 120}
```

- `stimulus_t` is seconds into the clip when the driver sent the input. Every time is measured from it.
- Keep the recorder's own timestamps: a recorder that writes a frame only when the screen changes
  (ScreenCaptureKit, `simctl io recordVideo`) shows a missed frame as a gap; a constant-rate one
  shows it as a repeated frame. Both measure the same. Never re-time a clip to constant rate.
- `unsupported: "<why>"` instead of a clip marks a flow the app does not have.

## What the numbers mean

- **Response**: stimulus to the first frame that changes in the flow's region. On the simulator
  this includes XCUITest's input latency (about one frame); on a Mac-hosted iPhone app, the
  synthesized event's. Compare like with like: the table's `Source` column says which.
- **Settle**: stimulus to the last change before 300 ms of stillness. **Motion** is settle minus response.
- **Dropped**: frame slots missed while moving, counted only where the next frame catches up
  (a slow spring tail moving less than a pixel a frame leaves gaps that are not drops).
- **Jumps**: one frame moving more than 2% of the screen at over 3x the speed of its neighbours.
- **Bursts**: separate bursts of change; more than 1 means the layout settled, then moved again (pop-in).
- **Spring**: the moving edge's travel fitted to SwiftUI's `.spring(response:dampingFraction:)`,
  with overshoot and the time to 90% of the travel. A fit RMSE above about 0.05 means it is not a spring.
