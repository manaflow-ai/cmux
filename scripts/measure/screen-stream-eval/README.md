# Screen stream eval

One harness that runs every screen stream we ship, and later other engines, through the same
fixed scenarios on one Mac, and writes numbers a later run can diff key by key
(HQ#7146 goal G0). It does no tuning and has no gate. It reports.

```
cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
  --ref SHA --artifact artifacts/screen-stream-eval/results.json [--arg=targets=rd,webrtc] [--arg=samples=200] [--arg=repeats=3]
```

`.github/workflows/screen-stream-eval.yml` runs it every day at the feat-cmux-next tip, started by
main's `screen-stream-eval-dispatch.yml` (scheduled workflows run only from the default branch). It
uploads `results.json` and a `summary.md` that shows each number's change against the last daily
run (the last successful one that dispatcher started).

## Scenarios (fixed)

| Scenario | What runs on the host | What is measured |
| --- | --- | --- |
| key, pointer | the glass-to-glass marker (`cmux-tui/crates/cmux-rd-host/scripts/mac-marker`), as the existing benches use it | one key press or click, then the time until a decoded frame shows the next counter; p50, p95, lost (1 s) |
| idle | `scene.swift`: a 5000-line code file at 13 pt Menlo, full screen, still for 30 s | kbps and fps the viewer received (each phase's first second dropped) |
| typing | the same view, 12 characters a second typed into its second line for 20 s | kbps, fps, encode and decode ms |
| scroll | the file scrolling at 600 pt a second for 20 s | kbps, fps |
| ocr | the top of the file, still; the host's `screencapture -x -D 1` 3 s in | Vision OCR character error rate of the viewer's last decoded frame against the host screenshot; the host's own OCR error against the drawn text as a check of the OCR |

The window (idle, typing, scroll) and OCR rows run `repeats` times (3 by default), each with a fresh
host, and report the median; `extra.repeats` keeps every repeat's numbers and the summary lists them.
One WebRTC run's OCR error and idle kbps move a lot from run to run (4.3 % and 12.9 %, 17 and 78
kbps on 2026-11-05), so a single repeat is not a number to compare. Latency runs once: its p50 and
p95 are already over `samples` inputs.

Changing a scenario changes what every earlier number means: give it a new schema version
(`SCHEMA` in `eval.py`) instead.

## Targets (pluggable)

A target is `targets/NAME.sh`, run as `bash targets/NAME.sh VERB ...` with `EVAL_ROOT` (the
checkout), `EVAL_BIN` (where built tools go), `EVAL_STATE` (the target's private scratch
directory, 0700) and, for latency, `EVAL_MARKER_LOG` (the marker's log: `marker-origin X,Y click-at X,Y`
and `stream width W px ... display (W, H)`). A view verb (`*-view`) is the viewer and writes the
viewer's raw output; it may run on another Mac ("Two Macs", where `EVAL_PEER` is the host's address
and `EVAL_BIND` the address the host binds). A report verb (`*-report`) turns it into the stable
form on the host Mac. The verbs are:

| Verb | Does |
| --- | --- |
| `build` | builds its host and viewer into `EVAL_BIN` |
| `host-start`, `host-stop` | starts its host on this Mac's main display at its defaults, and returns once the host is ready; stops it |
| `latency-view INPUT SAMPLES RAW`, `latency-report INPUT RAW OUT` | INPUT `key` or `pointer`: SAMPLES inputs on the marker through its viewer; OUT gets `{"g2g_ms": {"n", "p50", "p95", ...}, "lost", "split": {"input_to_capture_ms", "encode_ms", "transport_ms", "decode_ms", "method"}}` (transport: what is left between encode and decode, by each target's own method; not comparable across targets) |
| `window-view SECONDS FRAME GO RAW`, `window-report RAW OUT` | a viewer that sends nothing for SECONDS. It creates GO once its first frame shows, which starts the scene's timeline (the scene then holds its last screen until the harness stops it). FRAME gets the last decoded frame (PNG or PPM), and OUT gets `{"series": [{"unix_ms", "bytes", "frames", "decode_ms", "encode_ms"}], "extra"}`, one row a second |

Today's targets:

- `rd`: cmux.rd/1 (`cmux-tui/crates/cmux-rd-host`, the Mac viewer's path). The host runs with
  `--bind 127.0.0.1` and no other flags, and `cmux-rd bench` is the viewer, with VideoToolbox
  decode. `bench --input none --duration-s N` is the passive window.
- `webrtc`: `CmuxVNCWebRTC` `ScreenStreamHost` (the iPhone's path). `cmux-vnc-host --capture`
  runs with the default device hub signaling. The viewers are `RdMarkerClickLatencyTests`
  (`CMUX_RD_MARKER_INPUT=key|click`) and `StreamWindowTests`.

Adding one (for example Petal, https://github.com/kiruna-labs/petal) means writing
`targets/petal.sh` with these verbs and passing `--arg=targets=rd,webrtc,petal`. Its numbers then
appear under `targets.petal` in the same schema.

## Results

`artifacts/screen-stream-eval/results.json` (schema `cmux.screen-stream-eval/1`, the docstring of
`eval.py`) and `summary.md`. Each target also leaves its raw files under
`artifacts/screen-stream-eval/NAME/`, on the worker: the latency JSON and, per repeat N, `window-N.json`, `phases-N.jsonl`,
`host-N.png`, `viewer-frame-N`, `ocr-N.json`, and the logs, with pairing links redacted.

## Two Macs

By default host and viewer run on one Mac, so the network leg is loopback. For the LAN row, run two
steps at once, one on each Mac, with the same random `peer-token`:

```
token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
cmux-ci run ... --target-worker HOST_MAC --pin-strict --arg=lan=HOST_LAN_IP --arg=peer-token=$token
cmux-ci run ... --target-worker VIEWER_MAC --pin-strict --arg=viewer-of=HOST_LAN_IP --arg=peer-token=$token
```

The host Mac runs everything as usual (scene, marker, host bound to `lan`, OCR, results), and waits
up to 30 minutes for the viewer Mac. The viewer Mac builds the targets and runs `peer.py agent`. For
each scenario the host Mac hands its target's view verb (`latency-view`, `window-view`) to the
viewer Mac and gets back the raw result, the viewer frame and the clock offset between the two Macs.
It then runs the report verb (`latency-report`, `window-report`) itself. The rd host takes its own
opt-in for a private network (`--single-tenant-overlay 1`) only in this mode.

Clocks: the offset (host minus viewer, for CLOCK_MONOTONIC and the wall clock) comes from the round
trip with the least delay of 16, taken before and after each view. Its error is at most half that
round trip (about 0.25 ms on a quiet LAN), and the change between the two readings is recorded.
Glass-to-glass and decode are each measured on one Mac's clock. rd's input-to-capture and transport
cross the two Macs and are corrected by the offset.

Still not in glass-to-glass on either link: the viewer's own display. The numbers end when a frame
is decoded, not when it is presented on the viewer's screen. Real networks are G2.

Trust: the run token, rd's stream token and the WebRTC pairing link cross the LAN in plain HTTP.
The agent runs only the fixed view verbs, with checked arguments, from its own checkout. A measure
Mac's LAN is the boundary, as its console is (below).

## Needs

A console worker, and the grants: the hosts capture with ScreenCaptureKit and inject input with
CGEvent, and macOS gives them the Screen Recording and Accessibility grants of their responsible
app. A step's own processes usually hold neither, and the hosts are rebuilt at every commit, so a
grant on them would not last. So when `preflight.swift` finds no grants, the harness installs
`launcher/` as `CmuxScreenEvalLauncher.app` in the user's real `~/Applications` (a step's `$HOME` is scratch) (once; `install.sh` never replaces it,
since the grant is keyed to that exact binary) and runs the whole eval again inside it through
`open`. Every child of the app, the hosts included, then has its grants.

The one manual step per mini: grant Screen Recording and Accessibility to
CmuxScreenEvalLauncher in System Settings > Privacy & Security. The first run lists it there
(`launcher --request`). Until then the run writes `run.blocked`, naming the app, and exits 3.
macOS 15 and later may ask again, after some weeks, to keep allowing screen capture. A run blocked
again on a mini that ran before is that prompt waiting at its console.

**Trust.** The app holds both grants and runs the harness for any process of its user that asks:
the path check only guards against a wrong path, since that user can edit its own checkout anyway.
That matches the boundary a measure mini already has: a dedicated console user with no personal
data or secrets on screen, running only reviewed feat-cmux-next measurement steps, which run their
own checkout's code. Do not install the launcher on a Mac where that is not true.
