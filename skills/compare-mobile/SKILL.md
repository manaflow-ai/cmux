---
name: compare-mobile
description: "Compare a cmux-next iPhone app flow with Claude, Codex and the other chat apps in cmux-design-references, frame by frame: response time, animation length, the fitted spring, dropped frames, layout jumps and pop-in, with clips side by side. One command, `scripts/mobile-bench/compare-mobile FLOW`. Use when asked whether an iPhone flow (keyboard, composer, send, streaming, scrolling, sidebar, chat switch, attach, voice, settings, offline, launch) is as fast or smooth as the other apps, to measure an iOS animation, to fit spring parameters from a recording, or to get before/after numbers for an iOS perf or motion PR."
---

# compare-mobile

`scripts/mobile-bench/compare-mobile FLOW` captures our iPhone app at a pushed commit on a fleet iOS
simulator, measures the flow frame by frame, and prints it next to the same flow measured in the
other apps (cmux-design-references `apps/<app>-mobile/bench/`). Folder reference and metric
definitions: [scripts/mobile-bench/README.md](../../scripts/mobile-bench/README.md).

## Run it

```sh
scripts/mobile-bench/compare-mobile --list                     # flow ids
git push                                                       # it captures a pushed commit
scripts/mobile-bench/compare-mobile keyboard-show              # HEAD vs the references
scripts/mobile-bench/compare-mobile all --ref <sha>            # every flow at a commit
scripts/mobile-bench/compare-mobile composer-grow --ours DIR   # re-measure clips you already have
```

- It needs `cmux-ci` (the fleet client), ffmpeg (or `MOBILE_BENCH_FFMPEG=PATH`) and a checkout of
  manaflow-ai/cmux-design-references at `~/Projects/cmux-design-references` (or `--refs DIR`,
  `CMUX_DESIGN_REFS`). It builds nothing locally; the capture is one `cmux-ci run --class simulator`
  step, about 15 minutes with the queue.
- `OUT/table.md` lists the measurements and flows missing either recording. The verdict covers
  flows with paired measurements, and `OUT/slower.json` lists slower apps for those flows.
- A bold cell is worse than the best app by more than 10% and two frames; dropped frames, any more.

## Before and after for a PR

Run it at the base and at the head, then paste both tables into the PR's perf section:

```sh
scripts/mobile-bench/compare-mobile keyboard-show --ref "$(git merge-base HEAD origin/feat-cmux-next)" --out /tmp/kb-before
scripts/mobile-bench/compare-mobile keyboard-show --ref "$(git rev-parse HEAD)" --out /tmp/kb-after
```

## Add or change a flow

1. Add it to `scripts/mobile-bench/flows.json` (stimulus, response, settle, region, edge).
2. Add its test to `cmux-next-ios/UITests/MobileBenchFlowsUITests.swift`: idle a second, print
   `MOBILEBENCH flow=<id> event=stimulus t=<epoch seconds>`, do the input, wait until it settles,
   print `event=end`. A flow the app lacks prints `MOBILEBENCH flow=<id> unsupported reason=<why>`.
3. Capture the other apps (below) and run `compare-mobile <id>`.

## The competitors' clips

Use the same flow ID, stimulus and end state from `scripts/mobile-bench/flows.json` for both apps.
Keep comparison recordings in the private reference checkout. Screenshots can document layout.
Timing a transition needs the original recording and the time of the input on its timeline.

For layout references, save the publisher's current iPhone screenshots from the App Store:

```sh
python3 scripts/mobile-bench/storefront.py "$OUT/iphone-screenshots.zip" APP_STORE_ID [APP_STORE_ID ...]
```

The ZIP includes the images in listing order and a manifest with each version, storefront link,
image URL and retrieval time. Keep these publisher-selected screens alongside the device captures.

- For an iPhone app installed on a test Mac, run `scripts/measure/mobile-bench-mac-capture.sh` via
  the fleet. Its header gives the command and the `profile=` argument for the app's private input
  profile. Check the returned recorder rate and input timestamps.
- On a test iPhone, record the flow with idle frames on both sides. Record the input time relative
  to the first video frame. If that timestamp is unavailable, keep the clip as a visual reference.
- Save each timed recording as `apps/<app>-mobile/bench/<flow>/clip.mp4` with its `meta.json`.
  Use the clip contract in the benchmark README for device, OS, app version, source and
  `stimulus_t`. Run `compare-mobile <flow> --ours DIR --refs REFS --out OUT` to measure the
  saved clips and write `OUT/table.md` without starting another simulator. Inspect both clips
  at the reported response and settle frames before sharing a comparison.
- Compare like with like: the `Source` column says simulator, Mac-hosted iPhone app or device.
  A simulator runs on a Mac GPU and its input comes through XCUITest; read small differences
  (a frame or two) as noise, and confirm a real gap on a phone before calling it a regression.

## Measure any recording

`measure.py` works on any screen recording, not only these flows: make a folder with `clip.mp4`
and a `meta.json` naming a flow and `stimulus_t`, then `python3 scripts/mobile-bench/measure.py DIR`.
`cut.py` cuts a long recording into flows by `MOBILEBENCH` marker lines. Never re-time a clip to a
constant frame rate: dropped frames are read from the recorder's own timestamps.
