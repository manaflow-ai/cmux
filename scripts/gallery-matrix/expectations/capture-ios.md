# iOS captures for the visual expectation gate (plan)

The gate (`gate.ts`) judges iOS the same way as web and Mac once a CAPTURES folder holds
`ios/<surface>/<state>-<scheme>.png`, a sidecar `<state>-<scheme>.json` and `ios/renderer.json`.
This is how that folder gets made on owned fleet Macs, with the pieces that already exist and the
two that are new (one UI test file, one small adapter).

## 1. Route: the `simulator` fleet step

`scripts/ci/cmux-next-ios-sim.sh` already runs `xcodebuild test` of the `CmuxMobileAppUITests`
target on its own simulator, on the owned M4 Pro minis that advertise the `simulator` class
(never an agent host: huge-blue, big-red, air-blue and cosmic-gray take no builds or tests):

```
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
  --arg test --arg ui=VisualExpectationCaptureUITests \
  --artifact artifacts/ios-sim/evidence.zip
```

- `test` with `ui=` and no `only=` skips the kit tests and runs only that UI suite against a
  Debug app (`-only-testing:CmuxMobileAppUITests/VisualExpectationCaptureUITests`) on a new
  iPhone it creates and deletes by UDID (`$device_type`, `$runtime` chosen by the script).
- `keep_test_logs ... ui` already runs
  `xcrun xcresulttool export attachments --path ui.xcresult --output-path $out/ui-attachments`,
  which writes every `keepAlways` XCTAttachment as a file plus `manifest.json`, and the step zips
  `artifacts/ios-sim/` into `evidence.zip`.
- `cmux-ci run` streams the log and prints the job id; `cmux-ci artifact JOB DIR` downloads the
  zip (`--failed` gets what a failed step left, so states that did capture still reach the gate).
  On a lane VM `cmux-ci run` goes to the fleet client through the controller like `capture` does.

The script needs no change for this. The one optional change is a surface filter: forward
`surfaces=a,b` from `test`'s arguments as `TEST_RUNNER_CMUX_VISUAL_SURFACES=a,b` on the `ui`
`xcodebuild test` line (xcodebuild hands `TEST_RUNNER_*` to the test process without the prefix).
Until then every ios surface is captured in one run (a few seconds per state).

## 2. The test: `VisualExpectationCaptureUITests`

Draft: `scripts/gallery-matrix/expectations/VisualExpectationCaptureUITests.swift.draft`, to land as
`cmux-next-ios/UITests/VisualExpectationCaptureUITests.swift` (the target takes all of `UITests/`).

- Reads `design/visual-expectations/ios/*.json` from the worker's checkout, located from `#filePath`
  (a simulator test process runs on the Mac and reads host paths), so no expectation data has to
  pass through step arguments, whose pattern allows no spaces.
- Per scheme (light, then dark): sets `XCUIDevice.shared.appearance`, and for each capture launches
  the app with its `launch` arguments plus `-cmux-mobile-gallery-appearance <scheme>` and
  `CMUX_MOBILE_MOCK_AUTH=1` (as `TransientMaterialCaptureUITests` does), waits for
  `recoveryGallery.<scene>` (RecoveryGalleryRoot's identifier), then performs the test-side
  directives taken out of `launch` before the launch:
  - `-cmux-visual-tap ID`: tap that button (the sheet: `transient.openSheet`),
  - `-cmux-visual-wait ID`: wait for that element (the sheet: `Team appearance`),
  then waits for the hierarchy to settle (bounded) and attaches `app.screenshot()`.
- Attachment names carry the layout key: `vexp__<surface>__<state>__<scheme>` (PNG), one
  `vexp-meta` JSON (`scale`, `os`, `model`, `device`, `screen`), and on a state that does not show,
  `vexp-error__<surface>__<state>__<scheme>` (text) plus an XCTFail; `continueAfterFailure = true`
  so one broken state does not hide the others.

The directives exist because `CaptureSpec` has only `launch` for ios. If more states need
interaction, add `tap` / `waitFor` fields to `CaptureSpec` in `expectations.ts` and read them here
instead.

## 3. Mapping attachments to the layout (`capture-ios.py`, to write next)

Input: the downloaded `evidence.zip` (untrusted: unpack into its own empty folder, read with
`python3 -I`), the expectations dir, `--out CAPTURES`.

1. Read `ui-attachments/manifest.json`: a list of `{testIdentifier, attachments: [{exportedFileName,
   suggestedHumanReadableName, ...}]}`. The human-readable name is the attachment name with
   xcresulttool's `_<n>_<UUID>.<ext>` suffix; take the part before that suffix, and accept only
   names matching `^vexp(-error)?__([a-z0-9][a-z0-9.-]*)__([a-z0-9][a-z0-9.-]*)__(light|dark)$`
   or `vexp-meta`. Never follow a path in the manifest: `exportedFileName` must be a plain name of
   a regular file in `ui-attachments/`.
2. For each expectation capture and scheme:
   - PNG present: copy to `CAPTURES/ios/<surface>/<state>-<scheme>.png` and write the sidecar
     `{"scale": <meta.scale>, "keep": []}` (keep regions on iOS are boxes in points; the gate
     multiplies them by `scale`, 3 on current iPhones).
   - else: sidecar `{"scale": S, "keep": [], "error": <the vexp-error text, or "not captured:
     <step exit and the ui-tests-failures.txt line>">}` and no PNG (the gate reports missing/new).
3. `CAPTURES/ios/renderer.json` = `{"id": "<meta.os>; <meta.model> <meta.device> simulator @<scale>x;
   Xcode <version>"}`. The Xcode version comes from the step log (`xcodebuild -version` line, or add
   it to SUMMARY.md). Like the Mac adapter, it leaves out the app's build SHA (the thing under test:
   it would mark every PR as a renderer change) and the worker's host name (a private term).
4. Exit 1 when any state did not capture.

## 4. Determinism

- The status bar shows the clock and battery: the step should run
  `xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100
  --cellularBars 4 --wifiBars 3` on the `ui` device before `xcodebuild test` (a one-line change in
  `cmux-next-ios-sim.sh`), or every expectation keeps the top 54 points out of its keep boxes and
  sets a tolerance above the status bar's share of pixels.
- Same device type and runtime for baselines and PRs: the renderer id changes when the script's
  `$device_type` / `$runtime` pick changes, and the gate then only warns until the baselines are
  refreshed.
- Run each state twice in a baseline refresh; a state whose two shots differ gets
  `"nondeterministic": true` in its sidecar (adapter option `--repeat 2`), which the gate reports
  as flaky instead of changed.

## 5. Gaps

- `VisualExpectationCaptureUITests` and `capture-ios.py` are not written into `cmux-next-ios/`
  yet: `cmux-next-ios/` belongs to the iOS lanes (this worktree is sparse without it), and the
  test must compile on the fleet (`cmux-ci run --class simulator ... --arg build`) before it lands.
- The status-bar override and the `surfaces=` filter are small edits to `cmux-next-ios-sim.sh`.
- The sheet's keep box in `design/visual-expectations/ios/transient-sheet.json` and the toast's are
  estimates in points for a 402-point-wide iPhone; set them from the first real capture.
