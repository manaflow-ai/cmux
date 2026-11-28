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
main's `screen-stream-eval-dispatch.yml` (scheduled workflows run only from the default branch), with
the targets `rd,webrtc,iphone-sim` (`iphone-sim` last: it builds the app, and a target that fails or
is cut short leaves the earlier ones' results in `results.json`). It uploads `results.json`, `summary.md`, and `probe.json` (schema `cmux.screen-share-fast/1`) that the
screen-share-fast goal reads. The summary shows each number's change against the last daily
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

The archive holds one folder, `tools/`. Nothing is compiled on the bench Mac: the `rd`,
`apple-high` and `apple-standard` targets have this mode; WebRTC still requires its own build folder.
A Mac without the grants and without `CmuxScreenEvalLauncher.app` stops with exit 3 instead of compiling
the launcher. Apple targets require `screen-eval-window-id` in the archive and fail closed if it is absent
or not executable.

```
bash scripts/measure/screen-stream-eval.sh prebuilt=DIR targets=rd [repeats=3] [samples=200]
# On a second Mac with the prebuilt helper and a granted launcher:
bash scripts/measure/screen-stream-eval.sh prebuilt=DIR targets=apple-high,apple-standard viewer-of=HOST_IP peer-token=HEX
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
| `caps` (optional) | prints `window-only` for a target with no input path to time (`cu-png`, `rd-window`): the harness then skips its latency stage and judges it on its window rows alone. `latency-only` (`iphone-sim`) is the reverse: the latency stage, and no window or OCR repeats. A target without the verb runs both stages. `owes-ocr`, `owes-skips` and `owes-budget-bpp` lines name the numbers every run of it owes (`rd`: OCR error and encoder skips, plus budget bits per pixel with the ladder on, `rd-ladder`; `apple-*`: OCR error). A requested target that did not bring one (its scene did not start, its OCR calibration did not hold, a repeat lacks the number) makes the run exit 6, and its last line names the target and the field (`eval.py owed`); results.json is still written |
| `host-start`, `host-stop` | starts its host on this Mac's main display at its defaults, and returns once the host is ready; stops it |
| `latency-view INPUT SAMPLES RAW`, `latency-report INPUT RAW OUT` | INPUT `key` or `pointer`: SAMPLES inputs on the marker through its viewer; OUT gets `{"g2g_ms": {"n", "p50", "p95", ...}, "lost", "split": {"input_to_capture_ms", "encode_ms", "transport_ms", "decode_ms", "method"}}` (transport: what is left between encode and decode, by each target's own method; not comparable across targets). rd's split also has `input_to_capture_parts`: `{"render_ms", "sck_ms", "to_arrived_ms", "pickup_ms", "gate_ms", "arrived_to_release_ms", "encode_ms", "sck_all_frames_ms", "draw_ms", "commit_to_vsync_ms"}`, each `{"n", "p50", "p95"}`, from the host's per-frame timing log, plus `frame_before_commit` (a count) and `refresh_hz`. `draw_ms` and `commit_to_vsync_ms` come from the marker's `commit COUNTER T_US` lines (it logs them with `--verbose`). `sck_ms`, `sck_all_frames_ms` and `commit_to_vsync_ms` are signed: ScreenCaptureKit's display time is the vsync the frame is shown at, usually after the callback |
| `window-view SECONDS FRAME GO RAW`, `window-report RAW OUT` | a viewer that sends nothing for SECONDS. It creates GO once its first frame shows, which starts the scene's timeline (the scene then holds its last screen until the harness stops it). FRAME gets the last decoded frame (PNG or PPM), and OUT gets `{"series": [{"unix_ms", "bytes", "frames", "decode_ms", "encode_ms"}], "extra"}`, one row a second, each row stamped at the end of its second |

Today's targets:

- `rd`: cmux.rd/1 (`cmux-tui/crates/cmux-rd-host`, the Mac viewer's path). The host runs with
  `--bind 127.0.0.1` and no other flags, and `cmux-rd bench` is the viewer, with VideoToolbox
  decode. `bench --input none --duration-s N` is the passive window.
- `webrtc`: `CmuxVNCWebRTC` `ScreenStreamHost` (the iPhone's path). `cmux-vnc-host --capture`
  runs with the default device hub signaling. The viewers are `RdMarkerClickLatencyTests`
  (`CMUX_RD_MARKER_INPUT=key|click`) and `StreamWindowTests`. These are macOS test viewers: they
  end at decode and are not the phone.
- `iphone-sim`: the iPhone app's own viewer. The same host as `webrtc`; the viewer is the cmux-next
  iPhone app (Demo configuration: optimized, with the DEBUG developer surface) in an iOS simulator
  on the same Mac, launched with `CMUX_MOBILE_SS_LINK` (the host's pairing link, no sign-in or
  device hub; `ScreenSharingLinkRoot`, DEBUG only) and `CMUX_MOBILE_SS_MARKER`. Inside the app's
  `ScreenSessionView`, `ScreenPresentProbe` reads the marker from each decoded frame and times
  presents on whichever renderer `ScreenVideoView` has: each input (`ScreenSession.tap` of "a" or
  `click` on the click pad) is timed to the first decoded frame and to the first present that
  shows the next counter. "Presented" is, with an `RTCMTLVideoView`, the `targetTimestamp` of the
  first display link tick after the draw (the simulator's Metal reports no `presentedTime`; on a
  device the probe uses it); with an `AVSampleBufferDisplayLayer` (`DisplayImmediately`), the
  `targetTimestamp` of the first display link tick after the frame was enqueued (the scheduled
  scan-out, not measured). So one harness gives a before/after across a renderer change.
  `g2g_ms` is the presented time; `split.present` keeps decoded, presented and decode-to-present
  (each n, p50, p95), frames decoded but never presented, and `clock` (the renderer, what
  presented means for it, and its counts). The simulator runs on the Mac's clock.
  Not in it: the phone's touch or keyboard delivery before the session sends, the display's
  scan-out itself, a real phone's GPU, decoder and radio. Latency only (`caps`
  prints `latency-only`). It builds the app (FFI from the worker's cache, xcodegen, `xcodebuild`)
  and needs an iOS simulator runtime; a Mac with none stops at build, naming the runtimes it has:
  `--arg=targets=webrtc,iphone-sim`. One Mac only: with `lan=` or `viewer-of=` its build, host
  and view refuse, since a viewer Mac's simulator would have nothing on the host Mac to stop it.
  Its `host-stop` (also run by the harness's exit trap, on a signal too) deletes every simulator
  in its own `/tmp/iphsim.*` set and the set.
- `cu-png`: the computer-use preview's frame path as the app runs it today (`CmuxNextComputerUse`
  `ComputerUseLiveCapture`), replayed by `cu-png.swift` on the scene's window. It captures a window
  stream, reads it at 6 fps, scales it to 360 px on the long side, and encodes PNG and a base64
  `data:` URL. The target is host and viewer at once, so it has window rows only: no latency and no
  host. Its cost is a floor, because the app also copies each frame into the helper's ring, rounds
  the corners, evaluates JavaScript and decodes the PNG in the webview.
- `rd-ladder`: `rd` with the resolution ladder (`--resolution-ladder 1 --max-qp 40`) and a viewer that
  sends `video.scaled`, as the Mac viewer pane does; `rd-ladder-1000` pins it at 1000 kbps, where it
  steps down. `rd.sh` takes a variant's flags from `EVAL_RD_HOST_FLAGS` and `EVAL_RD_BENCH_FLAGS`.
- `rd-window`: the same window alone as a cmux.rd/1 stream at the same 360 px rung (`cmux-rd host
  --display window:ID --max-width 360 --max-fps 6`), with `cmux-rd bench` as the viewer.
  `rd-window-30` runs it at 30 fps. Both have window rows only.
- `apple-rfb`: Apple's Screen Sharing server measured headless, with no window on any Mac.
  `rfb-viewer.py` runs from a shell on the viewer Mac, logs in to the host's screensharingd with
  the host account (RFB security type 30, the login Screen Sharing.app uses), keeps one update
  request outstanding and decodes only the marker rows, so its pure-Python decoder never throttles
  the stream. Latency is an RFB key or click to the first decoded update whose marker counter
  changed (it ends at decode, like rd's `bench`); kbps is the RFB bytes it read; fps is the
  framebuffer updates that carried a rectangle; the OCR frame is one fully decoded framebuffer at
  the end of the hold. Readiness is the same fresh nonce as below, read from the framebuffer.
  The client offers ZRLE, zlib, CopyRect and raw (`encodings_seen` records what the server used),
  so this is Apple's server with standard RFB encodings, not the picture Screen Sharing.app gets
  over Apple's own encodings. The login is the one Screen Sharing.app saved in the viewer
  account's keychain for the host ("Remember this password"; the first read may show macOS's
  keychain prompt once), or a file in the viewer account's real home,
  `~/.config/screen-stream-eval/login` (mode 0600), which wins when present: the host account's
  password, for the account with the viewer's name (the fleet Macs share one), or a user name line
  first. Never argv, environment or logs. Each view runs under a hard time limit. Its viewer opens
  no window and posts nothing on its own Mac, so `viewer-of=` runs it from a person's Mac too;
  `person_guard.py` still refuses a person's Mac as its host, where its input lands.
- `apple-high` and `apple-standard` open Apple's Screen Sharing.app against the
  same host and sample the displayed connection for OCR and viewer CPU. They
  request Standard + Full Quality and Standard + Adaptive Quality respectively;
  neither is Apple's separate High Performance connection type. Connection
  setup still requires an authorized connection. The adapter selects and checks
  the quality menu item, then requires a fresh source nonce in the selected window
  before its window workload starts. kbps is the Screen Sharing.app process's
  received bytes from `nettop` (all its sockets, as `gui-viewer.sh` counts a
  third-party viewer), read at each one-second bucket's end; a failed read, or no bytes
  in the whole window, keeps every row's bytes null with `bytes_unavailable`
  rather than reporting zero. Decoded FPS and session time to first frame
  remain unavailable. The
  target records sampled screenshot changes separately as `sampled_fps`; this
  is a normalized observation rate, not decoded transport FPS. The target
  selects Full Quality for `apple-high` and Adaptive Quality for
  `apple-standard` directly through the app's View menu and fails closed when
  that menu cannot be selected. These items are available only in Standard
  connections ([Apple's macOS 26 guide](https://support.apple.com/en-us/guide/mac-help/mh14066/26/mac/26)).
  Select Standard during connection setup on the dedicated viewer. Apple
  targets require a second Mac and explicit `targets=`; the daily loopback
  targets remain `rd,webrtc,iphone-sim`.
  Each view launches its own Screen Sharing.app instance (`open -g -n`, never
  activated), binds its pid and window, quits only that pid when the view ends
  (success, failure or signal), and a watchdog ends a view that hangs; a
  Screen Sharing process the target did not start is never touched. Apple
  window runs require `presented-observer=1` with
  `presented-marker-origin=X,Y`, `presented-cell-size=N` and
  `presented-input-point=X,Y` (all coordinates are viewer capture pixels), plus
  optional `presented-display=main`, `presented-timeout-ms=1000` and
  `presented-seed=1`. The viewer step exports these values locally and runs its
  bundled `cmux-rd observe` against that exact visible window; it accepts only
  a complete `cmux.presented-marker/1` receipt. Without all values, Apple
  latency stays explicitly unavailable; screenshot sampling never becomes a
  latency claim. Each connection attempt reopens the documented View menu,
  verifies the selected check mark, binds the observed PID/window, and records
  `apple-connection.json` with the chosen quality profile and host.

### Source readiness and the common marker

Each Apple window repeat gets a fresh random 128-bit source nonce. The host passes it through the
existing peer command, and the viewer clears any nonce left from another repeat. After selecting
quality and binding the PID/window, the adapter runs `cmux-rd observe --mode passive` for one second
with `--expected-nonce HEX32`. Only a complete `cmux.presented-marker-series/2` receipt with the
expected nonce, verified host identity, matching PID/window and an advancing counter permits `GO`.
A connecting window, wrong host, old screenshot, frozen marker, missing observer or failed quality
selection cannot start the source workload. A failed host stops the scene before GO instead of
starting it for cleanup. This is source-scene identity evidence within the existing trusted peer
boundary; it neither authenticates a new Apple session nor changes hub approval or system grants.

`scene-marker=1` opts other targets into the same source layout; Apple's targets always use it.
The first row is the existing 20-cell marker (16 counter bits, LSB first, then guards 1,0,1,0).
Eight rows below carry nonce words in the same layout: canonical hex bytes `001122...eeff` become
little-endian words `0x1100, 0x3322, ..., 0xffee`. All nine rows persist throughout the repeat in
a reserved strip above the text. The readiness counter advances at 10 Hz before GO; thereafter it
advances only when a requested typing/scroll source frame is drawn. Idle does not animate. This
adapter still reports screenshot changes separately; it does not claim passive presented FPS.

`source-scene-N.json` records source layout in points, not viewer capture pixels. The selected
window may scale, offset or crop those points; calibrate the actual capture's marker origin/cell
size. Full-window OCR in this marker layout is unavailable until explicit matched host/viewer
pixel crops are calibrated. The source and viewer PNGs are retained; absent calibration produces
`comparison_ready:false` and null CER, never a full-window comparison. Legacy decode targets keep
their previous source layout unless `scene-marker=1` is supplied.

### Optional pinned video workload

Pass `video=/absolute/path/to/clip.mp4 video-sha256=HEX64` to add one 20-second video phase after
scroll. The path is operator-supplied and must already exist on the measurement Mac; the scene
verifies the SHA-256 before it opens the source window and refuses a missing, changed, generated or
downloaded clip. The current fixture provenance is Blender Big Buck Bunny `bbb_sunflower_1080p_60fps_normal.mp4`:
archive URL `https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_60fps_normal.mp4.zip`,
archive SHA-256 `68c456673409f8df09b80d0afe29ecb38ef110551fa8a93c83e54a96ebdaec78`, extracted
SHA-256 `3aa2d8946ec7cf3b50b7148fb3338ca421e6ec34987b20a4044845d674794e3e`, 355856562 bytes,
1920x1080 AVC1 at 60 fps, duration 634.5333333333 seconds. The harness uses only the first
20 seconds and records `video-requested.json` plus one `video-media-N.json` receipt containing the
same checksum, dimensions, nominal FPS, selected interval and actually presented decoded frames.
The video phase does not replace the fixed idle, typing, scroll or OCR phases.

Prebuilt runs need the updated `screen-eval-scene` and a `cmux-rd` that supports nonce observation;
`tools-only=1` packages both plus the window-ID helper. An older observer fails closed. Readiness
uses a precreated start signal and does not start its clock before connecting, so session time to
first frame remains null. No authenticated real-Mac comparison has been established by these tests.

The existing `rd` and `webrtc` targets use their passive bench viewers and end
at decode; those rows are not presentation comparisons with Apple. A common
comparison must drive the approved production Mac Screen pane through the hub,
put its visible window on the same viewer display, and pass that pane's exact
PID/window and capture-pixel marker geometry through the `presented-*` arguments.
The same `cmux-rd observe` receipt then supplies presented p50/p95 for each
contender. Hub connection identity, selected profile, scene/marker identity,
window bounds and capture dimensions are required artifacts; Apple transport
bytes and decoded FPS remain unavailable unless an approved counter exists.
No hidden decoder or alternate renderer is evidence for the table.

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

### External contenders (`eval.py external`)

A contender whose host and viewer live outside this repository plugs in through two commands, with
no target script here:

```
python3 scripts/measure/screen-stream-eval/eval.py external NAME OUT.json \
  --host-cmd 'start the host; touch "$EVAL_STATE/host-ready"' \
  --viewer-cmd 'connect, drive the marker, write "$EVAL_READBACK"' \
  [--host-stop-cmd CMD] [--takes 3] [--keep DIR]
```

The host serves the same marker (`cmux-rd testapp`, or `mac-marker`); the viewer decodes the stream,
reads the marker's counter from each decoded frame (`src/marker.rs`) and writes the readback, one
JSON line per key sample (`g2g_ms` or `lost`), per motion second (`bytes`, `frames`), the first frame
(`ms`) and each end's CPU (`eval.py external --help` lists the records). Each take gets a fresh host;
OUT.json is the usual target with `motion.kbps`, `motion.fps` and `extra.takes`, every number the
median of the takes that measured it, and a missing record stays null. `eval.py readback FILE OUT`
folds one readback without running anything, so the `rd` path's own bench output, converted to the
same records, lands in the same columns. Running `rd` through this hook too keeps one harness and one set
of definitions for every contender.

## Results

`artifacts/screen-stream-eval/results.json` (schema `cmux.screen-stream-eval/1`, the docstring of
`eval.py`) and `summary.md`. With more than one target, `summary.md` starts, after the run line, with a "Side by side"
table, one row per target: key and click glass-to-glass p50, kbps and fps in each window phase (a
viewer without frame counts shows its sampled screenshot changes, marked `*`). For `rd`, each window's additive `extra.netem_metrics` records
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
With the resolution ladder on, the host logs each frame's encoded picture size, and
`min_bits_per_pixel` and `median_bits_per_pixel` are encoded access-unit bits over that picture's pixels, across
emitted frames in the window; they stay null unless every emitted frame carries a size.
These observations remain under `extra.repeats[].window_netem_metrics` in the target summary.
There is no unqualified first-repeat or partial-repeat aggregate.
Each target also leaves its raw files under
`artifacts/screen-stream-eval/NAME/`, on the worker: the latency JSON and, per repeat N, `window-N.json`, `phases-N.jsonl`,
`host-N.png`, `viewer-frame-N`, `ocr-N.json`, and the logs, with pairing links redacted.

`probe.json` is the goal-facing row. It is complete only for a two-Mac run (`run.link` starts with
`lan`), with an `rd` key p50 and an Apple comparison target's key p50. A missing pair or comparison is
`outcome: unknown`; a complete run is `pass` only when the cmux key p50 is at most 160 ms, otherwise
`fail`. The row includes the exact source-results SHA-256, host/viewer/link/revision, and motion FPS
observations. It never invents a comparison number from a one-Mac loopback run.

`gate.json` is the budget gate (`budget_gate.py check results.json`; cmuxterm-hq
`docs/design/screen-share-under-100ms.md`, "Budget per stage", piece 6). It judges the `rd` target's
key split, stage by stage, against the page's p50 budgets: Screen (render), Capture (sck + pickup +
gate), Encode, Send + Network + Reassembly (transport, against the sum of the three budgets), Decode
and Total (to the decoded frame). Input and Present stay "not measured" until the per-frame stage
ledger (`cmux.rd-stage-ledger/1`) is in the target; a target that carries a
`cmux.screen-share-budget/1` record under `budget` (or a `screen-share-vs.py --out` file) is judged
from that record instead. A stage over budget fails the daily run with an error naming it; a run
that measured no stage fails too. The workflow's `budget` input (`STAGE=MS ...`) replaces budgets
for one dispatched run, to prove the gate end to end; the daily run passes none.

## Linux, kernel netem jitter (no Mac)

`rd-netem-linux.py` builds `cmux-rd` at each `--commit` and runs the Linux host (Xvfb,
`cmux-rd testapp --workload motion`, `--profile baseline`) and `cmux-rd bench --carrier udp` in two
network namespaces joined by a veth, with `tc netem` on each direction: clean, 5±5 ms,
15±15 ms with 1 % burst loss (Gilbert-Elliott, bursts of about 4 packets), 30±30 ms with 2 % loss.
Per commit and profile it writes one JSON line (`cmux.rd-netem-linux/1`): key-to-frame p50/p95 and
lost, received Mbps for every second of a 20 s passive session, the host's target kbps for every
second (its stats message), IDRs from the host's timing records, and the bench line's
`stage_ledger` (`cmux.rd-stage-ledger/1`) when that commit has one. `results.md` is the table;
`rd-netem-linux.py table results.jsonl` redraws it.

It needs root for `ip netns` and `tc` and a kernel with `sch_netem`, so on the fleet it runs through
HQ's netem route (cmuxterm-hq `docs/handbook/netem-route-without-host-module.md`), from an HQ checkout:

```
cmux-ci test --setup netem --timeout 7200 --artifact DIR -- bash -c 'set -e; d=$(mktemp -d);
  git -C "$d" init -q; git -C "$d" fetch -q --depth=1 https://github.com/manaflow-ai/cmux.git DRIVER_SHA;
  git -C "$d" checkout -q FETCH_HEAD -- scripts/measure/screen-stream-eval/rd-netem-linux.py;
  python3 "$d/scripts/measure/screen-stream-eval/rd-netem-linux.py" --deps --out "$FAST_CHECKS_OUT" \
    --commit FULL_SHA [--commit FULL_SHA ...]'
```

DRIVER_SHA is any commit with this script; each `--commit` is the cmux revision measured. A
prebuilt binary runs with `--bin LABEL=PATH` instead of `--commit`.

Hosts encode with Cisco's OpenH264 binary, the one shipped hosts load: the measured binary's own
`cmux-rd openh264-install` fetches it and checks its pinned SHA-256. `--openh264 PATH` uses a copy
you already have. `--openh264 source` keeps OpenH264 compiled from source by the `bench` feature.
That build has no assembly and encodes about 3x slower (`cmux-rd encode-selftest` at 1080p on the
pool: a typed glyph costs 15 to 20 ms from source and 6 ms with Cisco's binary). The tables mark
its rows "source-built, about 3x slower". They mark rows from before this flag the same way,
because those were all source-built, including #44486's 14.9 and 9.8 ms encode rows.

The build controller's Linux pool has `sch_netem` too and runs it from this repository directly
(the script exits 3 before measuring when `modprobe sch_netem` fails):

```
cmux-ci submit --kind fast-checks --label cmux-next-linux --repo https://github.com/manaflow-ai/cmux.git \
  --ref DRIVER_SHA --command 'set -e; out=${FAST_CHECKS_OUT:-$PWD/rd-netem-out}; mkdir -p "$out";
  python3 -u scripts/measure/screen-stream-eval/rd-netem-linux.py --deps --out "$out" --commit FULL_SHA'
cmux-ci wait JOB && cmux-ci log JOB
```

The JSON lines and the table are in the job's log.

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

The `apple-high`, `apple-standard`, and `moonlight` targets declare `viewer-grants` because their
viewers use `cmux-rd observe` to post input and capture the display. For these targets the viewer
checks Screen Recording and Accessibility and uses the same launcher as the host.

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

### Stage table on two Macs

`stage-table=LEGS` (for example `stage-table=wired,wifi-away`) runs the stage ledger
(`cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py run --legs LEGS --apple-viewer --app-viewer APP --app-host-app APP`) in place of
the targets, as the same two pinned halves, so any machine that submits fleet steps (a lane VM) runs it:

```
cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 --script scripts/measure/screen-stream-eval.sh \
  --ref SHA --pair KEY --target-worker HOST_MAC --pin-strict --arg=lan=HOST_IP --arg=peer-token=$token \
  --arg=stage-table=wired,wifi-away --artifact artifacts/screen-stream-eval/evidence.tar.gz --timeout 7200
cmux-ci run ... --pair KEY --target-worker VIEWER_MAC --pin-strict --vnc-login HOST_MAC --arg=viewer-of=HOST_IP \
  --arg=peer-token=$token --arg=stage-table=wired,wifi-away --artifact artifacts/screen-stream-eval/evidence.tar.gz
```

Both halves take the grant check and launcher first (the rig on the host, `cmux-rd observe` and Screen
Sharing.app on the viewer). The host half (`stage-table.sh host`) serves `screen-share-vs.py peer-serve`
on HOST_IP:4181; the viewer half builds the tools at its commit and runs the ledger with itself as
`--local-mac` and the host `--via peer`: each host command is one HTTP POST with the run token. The
server takes the first private-address client that holds the token and that one only, runs what it
posts as the step's user, and ends at the viewer's `/done` or after 2 hours. Apple's presented Total
logs in with the login the worker writes for a `--vnc-login` step (`CMUX_CI_VNC_LOGIN_FILE`), or,
with no `--vnc-login` (a controller with no fleet login source refuses it), with the fleet password
in the viewer's login keychain (`manaflow-fleet-login`, never the sudo item; `fleet-sudo --login-keychain VIEWER_MAC`
stores), copied to a 0600 file in the step's output for the run and removed after it. The
ledger, its log and the printed table are `stage-table/` in evidence.tar.gz.

cmux's Present and Total cells need a visible pane, so each half also builds a DEV cmux NEXT app at the
step's commit (`scripts/reload.sh --tag stagetable`, the build `chat-open.sh` does; logs
`app-build-host.log`, `app-build-viewer.log`). The viewer half passes its app as `--app-viewer` and the
host half's as `--app-host-app`. The host app is started as a direct child of the step, so it shares the
launcher's Screen Recording grant, signs in to the device hub, turns sharing on, and approves the viewer's
session; it tells the viewer half its path through the peer server (a file under `/tmp` named by the run
token's hash). Both apps sign in with `CMUX_STAGE_TABLE_AUTH_FILE`, else the Mac's
`~/rd-hub-rig/private/creds.env` (the Mac Screen rig's agent test-account file), else
`~/.secrets/cmuxterm-dev.env` (the CI dev account the pair e2e signs in with). With none of those files,
a half sent with `cmux-ci run --sign-in agent` signs its app in from the step's own agent session
(`CMUX_CI_SIGNIN_FILE`): `stage-signin.py` writes the session's refresh token into the app's own token
store before launch, as `scripts/ci/cmux_next_pair_e2e.py` does, and the store is removed when the step
ends. Send both halves with `--sign-in agent` (the viewer half without `--vnc-login`: a step takes one, and
it reads the fleet login from its keychain); only a submitter that holds the agent account can send it.
Without a file or a session on either Mac, or when a build or sign-in fails, the run keeps Apple's leg and the cmux rows end at decode, and
a `SCREEN-STREAM-EVAL-STAGE ... no app viewer` line says why. A shaped leg
(`wifi-away`) needs `sudo -n` on the host for mac-holds.sh; without it that leg fails and the table
holds the rest. Trust as above, except that this server runs any command it is handed, so the token
is the boundary inside the LAN.

### Held-and-burst link profiles

`mac-holds.sh` shapes the host Mac's egress to the viewer's addresses with dummynet, as root (on the
fleet, `fleet-sudo HOST /bin/bash mac-holds.sh ...`), and nothing else on the Mac:

```
mac-holds.sh start wifi-away 900 VIEWER_IP [VIEWER_WIFI_IP]   # a watchdog clears it after 900 s
mac-holds.sh holds                                            # each hold's start and end, CLOCK_MONOTONIC and wall
mac-holds.sh clear; mac-holds.sh show                         # show must list no pipe 07730
```

`wifi-away` comes from a Wi-Fi capture of a laptop away from its access point:
- 4 ms base delay and 2% random loss
- a 50 to 100 ms hold every 0.53 s
- long holds of 300 to 580 ms (median about 455 ms) at irregular gaps (median 3.4 s, 0.5 to 11 s)

A held packet is not dropped: it waits and leaves with the others at the hold's end. The schedule
comes from a fixed seed, and `wifi-away-schedule.jsonl` is that schedule for 900 s (`mac-holds.sh
schedule wifi-away 900`), so a later run can check it gets the same holds.
`wifi-short`, `wifi-long` and `wifi-loss` keep only the short holds, only the long holds, or only the
loss. `stall` is a 600 ms hold every 5 s.

The script refuses any pipe delay under 1 ms. A zero-delay dummynet pipe panicked a macOS fleet Mac
twice. `bash test-mac-holds.sh` checks the refusal with a stub `dnctl`, needs no root, and runs on Linux.

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
