# Computer Use driver eval

HQ#7146 G3a/G3b: how well each way of sending input, and each Cua Driver build, acts on an app
without disturbing the person at the keyboard. `scripts/measure/cu-driver-eval.sh` runs it on one
console Mac whose processes hold Accessibility and event posting. No fleet worker's step does, so
the fleet runs it inside the bench VM ([below](#bench-vm-scriptsmeasurecu-driver-benchsh)), where SIP
is off and the A/B's own executables are granted. `.github/workflows/cu-driver-eval.yml` does that at
the feat-cmux-next tip and writes a summary.md that compares each rate with the last successful run.
Scheduled workflows run only from the default branch, so a dispatcher on main starts it once a day.

```
cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
  --script scripts/measure/cu-driver-bench.sh --ref SHA --artifact artifacts/cu-driver-eval.tgz \
  --arg=suite=input-ab [--target-worker W] [--arg=reps=3] [--arg=drivers=cmux-cua,cua-driver-0.38.0] --timeout 7200
cmux-ci artifact STEP_ID cu-driver-eval.tgz
```

On a console Mac that has the grants, `cu-driver-eval.sh [reps=3] [drivers=...] [electron=0]` runs
the same A/B directly.

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
| `stamped-sl`, `stamped-cg` | the same stamped events, posted through only SkyLight or only `CGEventPostToPid`: `stamped-pid` posts both, and a gesture that arrives through both arrives twice |
| `cmux-cua-X.Y.Z` | the cmux-cua release at cmux's pin for this ref (`CMUX_CUA_RELEASE_TAG` and its hash in `scripts/build-cmux-cua.sh`; the release binary, without cmux's local patches), run as cmux runs it: inside a `cmux Computer Use.app` laid out as `build-cmux-cua.sh` assembles it (the binary refuses `serve` anywhere else), `serve --socket` on a socket of the run with exactly the app's helper environment (`ComputerUseHelperDaemon.environment`) and argv (cursor motion and owner pid when the manifest declares them), and `mcp --socket` with exactly acpmux's environment for it (`agent_tools.rs`: the agent token, `CMUX_CUA_MCP_FORCE_PROXY=1`, the cursor colors), with its own `click`, `press_key`, `scroll` tools. The app starts the helper through LaunchServices; here it is a child of the A/B |
| `cua-driver-0.38.0` | upstream Cua Driver v0.38.0 (`pins.json`), run as `mcp --direct`, the same tools |

Driver x,y are screenshot pixels: the scale comes from each driver's own `get_window_state`
(`screenshot_width` over `window_bounds.width`), recorded as `pixels_per_point`. The window layout
is derived from the main display's size (`layout()` in `input_ab.py`, down to 1280 x 800).

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

## Bench VM (`scripts/measure/cu-driver-bench.sh`)

The first stage of the bench: the pinned Lume (`pins.json` `lume`) clones the pinned
`trycua/macos-tahoe-cua:26.5.2` image (`image`; a moved tag is refused) for one run, sets 6 CPUs,
12 GB and 1920x1080, boots it headless, records what the guest has (`vm.json`: macOS, display,
SIP, Xcode tools, Homebrew, Python, Node), then deletes the clone. Given `base_url=`, the team's
Claude route, the step first checks that the worker reaches it and stops when it does not. Lume's image cache stays on the worker, so the 23 GB pull happens once. Lume pulls by tag
only, so the digest it logs for the manifest it fetched must equal the pin, or the base is deleted.

With `suite=input-ab` it then copies the A/B into the guest over SSH (a key made for the run),
gives the throwaway clone passwordless sudo, and starts `cu-driver-eval.sh` as a LaunchAgent in the
guest user's login session (`guest-start.sh`), so its windows are real windows. Once the A/B has
built its tools and fetched the drivers, `tcc-grant.sh` writes Accessibility, event posting and
screen capture for each of its executables into the guest's TCC databases and restarts tccd. The
step's artifact is the guest's `cu-driver-eval.tgz` with `vm.json` and `eval.log` added.

```
cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
  --script scripts/measure/cu-driver-bench.sh --ref SHA --artifact artifacts/cu-driver-bench.tgz \
  [--target-worker aws-m4pro-8] [--arg=base_url=http://HOST:PORT] [--arg=suite=route] --timeout 7200
```

### The model route (`suite=route`)

The bench's agent is `claude -p` in the guest. The guest stays off the team's network: an `ssh -R`
from the worker makes the guest's `127.0.0.1:4016` the route at `base_url=` (the worker opens the
connection; nothing listens beyond either loopback), and the forward's own ssh is the only process
the step stops. The pinned Claude Code (`pins.json` `claude_code`, the native binary of the version
Bench v2's registered runs used) goes to `/opt/homebrew/bin/claude`. `ANTHROPIC_BASE_URL` and the
route's placeholder token go into the clone's managed Claude Code settings
(`/Library/Application Support/ClaudeCode/managed-settings.json`), which Claude Code reads whatever
`--setting-sources` says, so the bench's scrubbed environment still gets them; they are written over
stdin, never into the image, an argv or a log. One `claude -p` with that scrubbed environment must
answer. A 529 or overloaded answer is retried after 15, 30 and 60 s and counted in
`vm.json` `route.retries`, apart from any result.

## Not here yet

- **Cua Driver Bench v2** (trycua/cua `libs/cua-driver-bench`, FSL-1.1-MIT: it is run, never
  copied here) in a macOS 26 VM at 1920x1080, with the setups cmux-cua, upstream Cua v0.38 and
  Peekaboo. The VM and the model route (`suite=route`) are here; the harness run is next.
- **A macOSWorld subset** with the model fixed and only the driver swapped, a snapshot reset per
  task. Same needs as the bench.
