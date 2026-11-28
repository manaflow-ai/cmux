# Native New Tab split acceptance

Run this against a capture of the current build for **each** Split Right and Split Down case.
The 900/450-pixel browser test exercises the current App cache/hydration path. The recorded
fixture tests validate this detector. Neither substitutes for this native capture check.

In an isolated app copy, focus the intended ordinary workspace and retain its snapshot.
Record `debug.motion` `trace_start`, then `debug.new_tab` `frame_strip` with the real split
key, `capture: "screencapturekit"`, `scale: 0.25`, and a PNG output directory. Stop the
motion trace and retain `debug.key` `{ "last": true }`. The executed action must have
`ran: true`. A dry-run action name is insufficient.

After at least three seconds, capture a second **keyless** `frame_strip` at the same
scale for at least six frames (250 ms), plus `debug.new_tab` `{ "action": "field" }`
and `debug.focus` `{}`. The focus receipt must name the inferred new pane as both resolved
and layout focus, and its resolved tab must match that pane's selected topology tab.
Keep its PNGs separate from the transition. Keep the video and a normal settled screenshot
for visual inspection of the intended composer, labels and workspace.

```sh
python3 scripts/cmux-next/new_tab_split_acceptance.py \
  --strip transition.json --trace motion.json --last-action action.json \
  --frames transition-pngs --settled-strip endpoint.json \
  --settled-frames endpoint-pngs --settled-field field.json --settled-focus focus.json \
  --direction right --source-sha FULL_BUILD_SOURCE_SHA --build-id BUILD_JOB_ID
```

The JSON receipt binds the supplied build identity to the direction, inferred new pane,
target geometry settle time, endpoint pixel hash and changed-pixel count for every frame
after geometry settles. Exit 0 requires all counts to be zero (RGB deltas of eight or less
are ignored), and a stable endpoint with content below the tab title. Motion elsewhere
in the window is excluded. Missing/refused actions, wrong geometry, short captures, blank
or changing endpoints and unequal capture scales fail. The script does not OCR the content;
review the video and endpoint to establish that the visible content is the intended composer.

Detector-only checks (the acceptance test is registered in the `linux-guard` fast lane;
changes to the detector select it through the focused test planner and the existing
PR pipeline's `new-tab-split-acceptance` step):

```sh
python3 tests/test_new_tab_split_acceptance.py
python3 scripts/cmux-next/test_split_scale_metrics.py
```

`fixtures/new-tab-split-baseline/capture.json` records the source build, capture step,
original artifact hashes and projection. Only target-pane crops are stored. The actual
baseline split was right despite a requested down action; it settled its geometry at
135.6 ms, remained empty at 138 ms, then painted the composer at 351 ms. These stored
artifacts can falsify a broken detector, but cannot establish current product behavior.
