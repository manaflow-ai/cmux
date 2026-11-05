# Computer Use driver eval

HQ#7146 G3a/G3b: how well each way of sending input, and each Cua Driver build, acts on an app
without disturbing the person at the keyboard. `scripts/measure/cu-driver-eval.sh` runs it on one
console Mac; `.github/workflows/cu-driver-eval.yml` runs it every day at the feat-cmux-next tip and
writes a summary.md that compares each rate with the last scheduled run.

```
cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
  --script scripts/measure/cu-driver-eval.sh --ref SHA --artifact artifacts/cu-driver-eval.tgz \
  [--target-worker W] [--arg=reps=3] [--arg=drivers=cmux-cua,cua-driver-0.38.0] [--arg=electron=0] --timeout 3600
cmux-ci artifact STEP_ID cu-driver-eval.tgz
```

## Input A/B (suite `input_ab`)

Two windows of our own, built from source on the worker: the user's window (`apps.swift witness`)
and a target. The targets are an AppKit window (`native`), a WKWebView page (`webkit`) and the same
page in Electron 43.8.1 (`electron`, the version Cua Driver Bench v2's taskpack pins). Each target
logs what it actually received: `sendEvent:` for AppKit, DOM events for the two web targets. Every
route here is fire-and-forget, so "posted" is never counted as "delivered" (Petal learnt this the
hard way: `remote_control.rs` #446).

Each trial sends one gesture (a click, the key `a`, or 5 wheel lines) to a point of the target that
the user's window does not cover, in two conditions:

- **background**: the user's window is frontmost and key, and partly covers the target.
- **foreground**: the target is frontmost and key.

Arms (`inject.swift` for the routes, MCP stdio for the drivers):

| arm | what it does |
|---|---|
| `cg-pid` | `CGEventPostToPid`, a plain CGEvent at the screen point |
| `sl-pid` | SkyLight `SLEventPostToPid`, the same event |
| `session-tap` | `CGEventPost` at the session tap; moves the pointer |
| `nsevent-pid` | an `NSEvent` with the target's `windowNumber` and a window-local location, converted to a CGEvent, posted to the pid (Hopp's idea; Hopp is AGPL, so idea only, no code). No scroll: NSEvent has no public wheel constructor |
| `stamped-pid` | Cua Driver's event fields (1, 3, 7, 40, 51, 58, 91, 92, `CGEventSetWindowLocation`, a `mouseMoved` primer), posted through SkyLight then CGEventPostToPid, without its focus step. Ported from trycua/cua (MIT) |
| `cmux-cua-X.Y.Z` | the cmux-cua release cmux ships at this ref (`CMUX_CUA_RELEASE_TAG` in `scripts/build-cmux-cua.sh`), with its own `click`, `press_key`, `scroll` tools |
| `cua-driver-0.38.0` | upstream Cua Driver v0.38.0 (`pins.json`), the same tools |

Per trial it records: delivered (the target got the whole gesture), duplicates, click position
error, and in the background condition the disturbances Cua Driver Bench v2 counts: a focus steal
(the frontmost app changed, or the user's app resigned active), key loss (the user's window
resigned key), a window raised over the user's window, the pointer moved more than 1 pt, and input
that landed in the user's window. **Clean** is delivered with none of those.

## Output

`artifacts/cu-driver-eval.tgz` holds `cu-driver-eval/results.json`, `summary.md`,
`input-ab/trials.jsonl` and every app's log. results.json (schema `cmux.cu-driver-eval/1`,
docstrings of `eval.py` and `input_ab.py`):

- `run`: `at`, `host`, `cpu`, `macos`, `rev`, `display`, `reps`, and `blocked` when nothing ran.
- `suites.input_ab`: `arms`, `targets`, `grants`, `errors`, `rows["ARM|TARGET|GESTURE|CONDITION"]`
  (`n`, `delivered`, `delivered_rate`, `clean`, `clean_rate`, `duplicates`, `focus_steals`,
  `key_losses`, `raises`, `pointer_moved`, `stray`, `loc_err_max`, `call_ms_p50`, `unsupported`,
  `errors`) and `wins[TARGET][GESTURE]`.

A count nobody could measure is null, never left out, so two runs line up key by key.

## Not here yet

- **Cua Driver Bench v2** (trycua/cua `libs/cua-driver-bench`, FSL-1.1-MIT: it is run, never
  copied here) in a macOS 26 VM at 1920x1080, with the setups cmux-cua, upstream Cua v0.38 and
  Peekaboo. It needs a VM route on the fleet and a credential-free Claude route into the VM
  (the team subrouter, as `scripts/measure/team-eval.sh` does).
- **A macOSWorld subset** with the model fixed and only the driver swapped, a snapshot reset per
  task. Same needs as the bench.
