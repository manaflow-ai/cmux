# Screen stream eval

One harness that runs every screen stream we ship, and later other engines, through the same
fixed scenarios on one Mac, and writes numbers a later run can diff key by key
(HQ#7146 goal G0). It does no tuning and has no gate. It reports.

```
cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
  --ref SHA --artifact artifacts/screen-stream-eval/results.json [--arg=targets=rd,webrtc] [--arg=samples=200] [--arg=repeats=3] \
  [--arg=input-frame-now=1] [--arg=netem-rtt-ms=50 --arg=netem-loss-pct=2 --arg=netem-seed=7]
```

`input-frame-now=1` starts the rd host with `--input-frame-now 1` (an input lifts its frame-rate cap
for 100 ms), for a before/after against a run without it at the same commit.

`netem-rtt-ms`, `netem-loss-pct`, and `netem-seed` add a deterministic user-space relay to the `rd`
target's loopback connection. The relay applies half the RTT in each direction and seeded UDP loss;
TCP is delayed but not dropped. This measurement mode is rejected for two-Mac runs.
The viewer explicitly registers its UDP socket with the relay and advertises the relay's
port in Hello, so downstream media and upstream feedback both traverse shaping.
`netem-stats.json` records cumulative received, dropped and sent counts in each direction;
these are path diagnostics, not a matched wire-bandwidth comparison with another target.

`.github/workflows/screen-stream-eval.yml` runs it every day at the feat-cmux-next tip, started by
main's `screen-stream-eval-dispatch.yml` (scheduled workflows run only from the default branch). It
uploads `results.json` and a `summary.md` that shows each number's change against the last daily
run (the last successful one that dispatcher started).

## Prebuilt tools

A Mac that must not build (a laptop cleared for benches only) runs the harness from a copy of
`scripts/measure` with `prebuilt=DIR`, where DIR holds tools built elsewhere for that Mac: `cmux-rd`
(`cargo build --release` in `cmux-tui/crates/cmux-rd-host`), `screen-eval-preflight`,
`screen-eval-scene`, `screen-eval-ocr`, and for a third-party viewer `screen-eval-window-id` and
`screen-eval-marker-locate` (`swiftc -O` of the `.swift` files here) and `cmux-rd-marker`
(`swiftc -O` of `cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift`), plus an optional `rev`
file naming the commit they were built from (`run.rev`). A fleet step builds them all at one commit,
with no console or grant needed:

```
cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/screen-stream-eval.sh \
  --ref SHA --arg=tools-only=1 --artifact artifacts/screen-stream-eval/tools.tar.gz
```

The archive holds one folder, `tools/`. Nothing is compiled: only the `rd` target
has this mode, and a Mac without the grants and without `CmuxScreenEvalLauncher.app` stops with exit 3
instead of compiling the launcher.

```
bash scripts/measure/screen-stream-eval.sh prebuilt=DIR targets=rd [repeats=3] [samples=200]
```

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
| `caps` (optional) | prints `window-only` for a target with no input path to time (`cu-png`, `rd-window`): the harness then skips its latency stage and judges it on its window rows alone. A target without the verb runs both stages |
| `host-start`, `host-stop` | starts its host on this Mac's main display at its defaults, and returns once the host is ready; stops it |
| `latency-view INPUT SAMPLES RAW`, `latency-report INPUT RAW OUT` | INPUT `key` or `pointer`: SAMPLES inputs on the marker through its viewer; OUT gets `{"g2g_ms": {"n", "p50", "p95", ...}, "lost", "split": {"input_to_capture_ms", "encode_ms", "transport_ms", "decode_ms", "method"}}` (transport: what is left between encode and decode, by each target's own method; not comparable across targets). rd's split also has `input_to_capture_parts`: `{"render_ms", "sck_ms", "pickup_ms", "gate_ms", "encode_ms"}`, each `{"n", "p50", "p95"}`, from the host's per-frame timing log |
| `window-view SECONDS FRAME GO RAW`, `window-report RAW OUT` | a viewer that sends nothing for SECONDS. It creates GO once its first frame shows, which starts the scene's timeline (the scene then holds its last screen until the harness stops it). FRAME gets the last decoded frame (PNG or PPM), and OUT gets `{"series": [{"unix_ms", "bytes", "frames", "decode_ms", "encode_ms"}], "extra"}`, one row a second, each row stamped at the end of its second |

Today's targets:

- `rd`: cmux.rd/1 (`cmux-tui/crates/cmux-rd-host`, the Mac viewer's path). The host runs with
  `--bind 127.0.0.1` and no other flags, and `cmux-rd bench` is the viewer, with VideoToolbox
  decode. `bench --input none --duration-s N` is the passive window.
- `webrtc`: `CmuxVNCWebRTC` `ScreenStreamHost` (the iPhone's path). `cmux-vnc-host --capture`
  runs with the default device hub signaling. The viewers are `RdMarkerClickLatencyTests`
  (`CMUX_RD_MARKER_INPUT=key|click`) and `StreamWindowTests`.
- `cu-png`: the computer-use preview's frame path as the app runs it today (`CmuxNextComputerUse`
  `ComputerUseLiveCapture`), replayed by `cu-png.swift` on the scene's window. It captures a window
  stream, reads it at 6 fps, scales it to 360 px on the long side, and encodes PNG and a base64
  `data:` URL. The target is host and viewer at once, so it has window rows only: no latency and no
  host. Its cost is a floor, because the app also copies each frame into the helper's ring, rounds
  the corners, evaluates JavaScript and decodes the PNG in the webview.
- `rd-window`: the same window alone as a cmux.rd/1 stream at the same 360 px rung (`cmux-rd host
  --display window:ID --max-width 360 --max-fps 6`), with `cmux-rd bench` as the viewer.
  `rd-window-30` runs it at 30 fps. Both have window rows only.

The window targets add `extra.process_cpu_pct`, the CPU of the process that captures and encodes,
over the view. Compare them in one run with `--arg=targets=cu-png,rd-window,rd-window-30`
(hq#9837, fix 2).

- `moonlight`: Sunshine as the host and Moonlight as the viewer, each at its defaults (Moonlight's
  are 1080p60 at 20 Mbps, so a larger host display reaches the viewer scaled down, as a person
  gets it). Two Macs only, since on one Mac the viewer would stream its own window back into itself.
  Sunshine (`brew install lizardbyte/homebrew/sunshine`) on the host Mac and
  `/Applications/Moonlight.app` on the viewer Mac are installed once by a person; the target installs
  nothing and pairs by itself (a fresh PIN per host start, handed to the viewer Mac like rd's token,
  and Sunshine's state kept in the real home's `~/.cmux-screen-eval/sunshine` so a Mac pairs once).

### Third-party viewers (`gui-viewer.sh`)

A viewer cmux did not write gives no frame timestamps or stats, so `gui-viewer.sh` measures it from
outside, the same way for every contender (Moonlight here; Screen Sharing.app and Windows App
can use the same functions):

| Row | How |
| --- | --- |
| key, pointer | `cmux-rd observe` (cmux-rd-host `src/mac/observe.rs`), which knows no protocol: it posts each key or click to the viewer's process and times it to the ScreenCaptureKit frame of the viewer Mac's display in which the host's marker counter changed. `screen-eval-marker-locate` (`marker-locate.swift`) first finds where the viewer draws the marker, and at what cell size, in observe's pixels. This ends at the compositor, a little later than rd's and WebRTC's decoded frame, so it slightly favours them |
| kbps | the viewer process's received bytes from `nettop`, all its sockets, so headers, FEC and resends count, as rd's datagram count does |
| fps | null: the viewer does not expose frames. Each row's `sampled_changes` counts window captures (10 a second) that differ from the one before, which shows that the screen updated but is not a frame rate |
| OCR | the viewer window's last capture against the host's screenshot |
| CPU | `extra.viewer_cpu_pct`, the viewer process over the window view |

`python3 -m unittest scripts/measure/screen-stream-eval/test_eval_null_counts.py` checks that a
null count gives a null number rather than a wrong one.

### OS pairs and contenders

Host → viewer. Today the only viewer cmux ships is the Mac app's (Mac Screen, `MacScreenSession`).
`cmux-rd bench` decodes on Linux but shows nothing, and Windows has no viewer. So every comparable
pair has a Mac viewer, and `gui-viewer.sh` can time each contender in it.

| Pair | cmux | Sunshine/Moonlight | Windows App (RDP) | macOS Screen Sharing | In this harness |
| --- | --- | --- | --- | --- | --- |
| Mac → Mac | rd/1 and WebRTC | `moonlight` | no RDP host on macOS | #42264 (`apple-*`) | yes (two Macs) |
| Linux → Mac | rd/1 (X11, Cloud desktop) | Sunshine on Linux | xrdp or GNOME Remote Desktop | VNC only | no: the scene and marker are Mac apps |
| Windows → Mac | headless proof only (`cmux-rd-windows.yml`) | Sunshine on Windows | the native RDP host | no | no: the same, plus no rd host in `serve` on Windows |
| Mac → Linux, Mac → Windows, and every Linux or Windows viewer | no viewer | Moonlight runs there | Windows App runs on Windows | no | no |

The Linux and Windows host rows need a scene and marker on that OS (the observer and the viewer
side stay as they are on the Mac). The viewer columns need a cmux viewer on Linux and Windows first.

Adding one (for example Petal, https://github.com/kiruna-labs/petal) means writing
`targets/petal.sh` with these verbs and passing `--arg=targets=rd,webrtc,petal`. Its numbers then
appear under `targets.petal` in the same schema.

## Results

`artifacts/screen-stream-eval/results.json` (schema `cmux.screen-stream-eval/1`, the docstring of
`eval.py`) and `summary.md`. For `rd`, each window's additive `extra.netem_metrics` records
per-encode attempts, emitted frames, skips, IDRs, P frames, received video/FEC bytes and bitrate.
Decoded FPS counts successful decoder output. On-time FPS counts frames decoded within 100 ms
of the source's captured display-frame timestamp, joined to decoder completion by the exact
encode-request key. It requires a same-host clock and complete, non-truncated timing records;
protocol encode-start timestamps alone do not establish capture latency. Missing evidence is null.
These are headless decoder endpoints, not visible pane or phone presentation metrics.
Quality uses a bounded 128x64 luma ROI, matched by timestamp and exact encoded access-unit bytes.
A source PNG and last viewer image with equal dimensions do not establish frame identity.
Five source samples at most are recorded per host session, and quality is not extrapolated to
other scene phases. `evidence.tar.gz` retains raw decode/timing records and matched ROI samples.
These observations remain under `extra.repeats[].window_netem_metrics` in the target summary.
There is no unqualified first-repeat or partial-repeat aggregate.
Each target also leaves its raw files under
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

On the fleet's minis, use the host's tailnet address (`100.x`) for `lan` and `viewer-of`: macOS Local
Network privacy refuses LAN addresses to the binaries a step starts (Apple's own, such as `nc`, are
exempt, so a shell probe proves nothing), while the tailnet path between two Macs on one LAN is direct,
inside WireGuard. The summary's link then says `lan via tailnet`.

A third-party viewer target (its `caps` prints `viewer-grants`, as `moonlight` does) also needs
Screen Recording and Accessibility on the viewer Mac, where `cmux-rd observe` posts input and
captures the display: that half then takes the same grant check and launcher as the host.

The host Mac runs everything as usual (scene, marker, host bound to `lan`, OCR, results), and waits
up to 30 minutes for the viewer Mac. Submit the viewer half first and the host half once the viewer's
step is running (its log shows `SCREEN-STREAM-EVAL-STAGE viewer`): a pinned Mac that is busy with other
steps can hold the viewer back for longer than the host's wait, and the viewer itself waits 30 minutes
for the host. The viewer Mac builds the targets and runs `peer.py agent`. For
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
