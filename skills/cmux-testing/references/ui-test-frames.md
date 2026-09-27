# See what a UI test did

Use this when a UI or E2E test passes or fails and you need to see the app, not
just the assertion. It needs no screen recording, so it works on the owned
minis (which record no video) and on runners whose screen capture is broken.

## Run a test and get its frames

```bash
python3 scripts/ci/dispatch-focused-test.py cmuxUITests/SidebarHelpMenuUITests --ref <pushed-sha> --frames
```

`--frames` implies `--wait`. When the run ends, it prints each test's result,
the first line of each failure, the frame nearest the failure, named captures,
and contact sheets.

For a run that already finished, pass its id or URL:

```bash
python3 scripts/ci/e2e-frames.py https://github.com/manaflow-ai/cmux/actions/runs/<id> [--test Substring]
```

## What you get

Under `$TMPDIR/cmux-e2e-frames/<run>/<Class>/<method>/`:

| File | Use |
| --- | --- |
| `sheet-N.png` | 3x4 grid of the steps in time order, 1920 px wide. Open these first. |
| `frames/NNN-step.png` | XCUITest's screenshot for one step, 960 px wide. |
| `frames/NNN-<name>.png` | A named capture the test attached. |
| `steps.mp4` | The frames at 2 fps, for a person to scrub. |

`--json` prints the same summary for scripts.

## Know the limits

- XCUITest keeps step screenshots only for failing tests. For a passing test you
  get named captures only, so attach the views you want to see:
  `let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "account-menu"; shot.lifetime = .keepAlways; add(shot)`.
- Read the result, not just the exit code. **Expected Failure** usually means the
  harness absorbed a launch or activation failure and the test ended before
  it reached the behavior under test.
- A run that failed before tests started uploads no `test-results`, so there
  is nothing to extract; its log explains why.
- Look at the whole frame. Leftover system dialogs (crash reports, keychain
  prompts) over the app explain activation and focus failures;
  the "Close leftover system dialogs" step in `.github/actions/e2e-run-tests` closes them before each run.
