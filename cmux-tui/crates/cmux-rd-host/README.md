# cmux-rd-host

The host engine of the cmux remote desktop and its bench client: on Linux a virtual X display
such as Xvfb on servers and Cloud VMs (phase 1); on macOS the Mac's own display through
ScreenCaptureKit, VideoToolbox and CGEvent (`plans/cmux-next/remote-desktop-mac-host.md`). Design and decisions:
`plans/cmux-next/remote-desktop.md`. Wire format: `cmux-rd-proto`. Pure logic (FEC,
packetizer, reassembly, frame gate, congestion control, input, sessions and access
policy): `cmux-rd-core`.

```
cmux-rd host    --listen-systemd --peer-uid 1000 [--display :99] [--xauthority PATH] [--idle-exit-s 120] [--no-udp-link] [--link-stun HOST:PORT,...]   (Cloud machines; below)
cmux-rd host    --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99] [--port 4103] [--codec openh264] [--upstream-record DIR [--upstream-record-max-mb 1024]]
cmux-rd bench   --addr HOST:4103 --token-fd N [--carrier udp|stream] [--mode view|control] [--samples 300] [--user USER] [--upstream mic|camera|screen --upstream-frames 100]
cmux-rd testapp --display :99 --workload marker|text|motion|idle
```

The bench requests control by default. With `--mode view --input click --samples 1`,
it sends the same click and watches the decoded marker for one second. In the active
bench report, `input_sent` counts attempted samples and `input_acked` records whether
the host acknowledged the last event. A view-only host acknowledges discarded input.
`marker_changes` counts observed counter changes after the first sample begins, and
`g2g_ms` measures the time to the expected counter for each successful sample.

## macOS host

```
cmux-rd host --owner USER --token-fd N [--display main|INDEX] [--max-fps N (default: the display's refresh rate, else 60)] [--profile high|baseline] [--encode-profile standard|ultra]
```

The codec is always `videotoolbox`, fed the captured IOSurface with no copy. The process, or
the app that started it, needs Screen Recording and Accessibility.
`scripts/mac-host-run.sh BIN_DIR STATE_DIR [--motion]` starts the host and the glass-to-glass
marker app (`scripts/mac-marker`, build with `swiftc -O`) on a test Mac; `cmux-rd bench`
from another Mac then measures latency (`--snapshot FILE.ppm` keeps the newest decoded frame).
Build on a fleet Mac: `cargo build --release --no-default-features --features bench`.

## Approved Mac-to-Mac WG media

`serve` and `connect` keep the signed hub session's Noise link for admission,
reliable control, candidate routing and revocation. A fresh ephemeral cmux-wg
session carries media inside its authenticated datagrams when the signed offer
and answer select `rd_wg/1`; no private WG key is signaled. For WG, `connected`
is emitted only after both sides report WG readiness.
The media MTU accounts for WG padding and the inner IP/UDP header. Both the
outer media queue and per-session queues are bounded.

Process Setup/Answer accept optional `peer_carrier`: omission preserves the
original rd-link media protocol for legacy peers, while the exact string
`rd_wg/1` selects WG before networking starts. Any supplied unknown, empty,
null or malformed value fails closed. The app forwards the peer's authenticated
`a=fingerprint:cmux-rd-carrier rd_wg/1` marker, and the host echoes its selected
marker only after Rust accepts Setup. Mixed old/new pairs therefore keep their
original protocol; two updated peers select WG. This initial legacy selection
is not a fallback: a selected WG session can never switch to bare rd media.
The updated app invokes `cmux rd serve-v2` or `cmux rd connect-v2`. These
versioned aliases prove the worker implements signed carrier selection; old
workers reject them before emitting any key. Old app callers retain `serve`
and `connect`. This also prevents an old dev override from falsely advertising
WG through new Swift. The bundled `bin/cmux` and app still need an integrated
artifact check; Swift-only validation is insufficient.

Before readiness, an unsupported or failed WG negotiation proposes a typed
WebRTC retry. Both sides acknowledge the proposal, and each waits until its
outgoing acknowledgement has been delivered before emitting a fallback app
line. Missing acknowledgements expire after three seconds and end the session.
This is not atomic agreement under arbitrary loss: if one process exits and its
final outer acknowledgement is lost, the other peer may end the session instead
of retrying. A terminal close always wins over retry; no peer waits indefinitely.
Old peers without this exchange therefore fail closed; they never receive bare
rd-link media. Stop, consent/revocation, peer authentication failure, and failures
after readiness never permit a retry. The app consumes this decision on the
original approved ticket (the schema/FFI integration is a prerequisite).

This layering preserves existing authorization without a new hub trust model,
but adds WG encryption and an inner IP/UDP header to rd-link. The existing
`cmux-remote` shared WG hub `datagram.bind` API is a separate carrier endpoint;
Mac Screen's current signed setup does not carry its socket/configuration.
Real-Mac comparison numbers are required before claiming a latency/fps benefit
or closing #42196. This implementation alone is not performance evidence.

Focused transport checks (on managed CI):
`cargo test --manifest-path cmux-tui/crates/cmux-rd-host/Cargo.toml --features link wg_`.

For transport, encoder and controller measurements without any grant, a bench build of
`cmux-rd host` or `cmux-rd serve` takes `--source synthetic|synthetic-still|synthetic-tick
[--synthetic-size WxH] [--synthetic-scene bars|text|noise|churn]` (default 1920x1080 bars, fitted to `--max-width`): it streams a generated
NV12 picture with the marker at 0,0 through the same VideoToolbox and send path, and a
viewer's key press, click or scroll bumps the marker instead of reaching the Mac.
`synthetic` moves bars every frame, `synthetic-still` sends a frame only when input bumps
the marker, and `synthetic-tick` also counts every frame (the fps probe). Flat bars compress
to almost nothing; `text` (dense glyphs scrolling 4 px a frame) and `noise` (grain-textured
bars) translate, which an encoder predicts cheaply; `churn` (the grain at a new random
offset every frame) is new content every frame. The two-Mac
harness runs it over ssh with no rig and no marker app:
`scripts/screen-share-vs.py run --source synthetic --stacks cmux --via ssh --host A --viewer B
--host-ip IP --bin cmux-rd` (key trials use `synthetic-still`, fps trials `synthetic-tick`).

### Before and after numbers: the budget table

Every screen-share change quotes its before and after from one command, which runs cmux and
macOS Screen Sharing on the same motion scene between two Macs and prints the stage budget table
(Input, Screen, Capture, Encode, Send, Network, Reassembly, Decode, Present, Total, each p50/p95),
received Mbps and motion quality (a frame score and the text error against the source):

```
# tools/ built at your head (no compiling on the Macs); repeat at the merge base for "before"
cmux-ci run --class exclusive --measurement --label measure \
  --script scripts/measure/screen-stream-eval.sh --ref "$(git rev-parse HEAD)" \
  --arg=tools-only=1 --artifact artifacts/screen-stream-eval/tools.tar.gz
tar -xzf tools.tar.gz
scripts/screen-share-vs.py run --host SHARED_MAC --viewer VIEWING_MAC --host-ip SHARED_MAC_LAN_IP \
  --tools ./tools --label after --cua-vnc PATH/cua-vnc \
  --vnc-user USER --vnc-password-file PATH_ON_VIEWING_MAC --out after.jsonl
scripts/screen-share-vs.py compare before.jsonl after.jsonl
```

`--host-arg=ARG` adds a `cmux-rd serve` flag and `--viewer-arg=ARG` a `cmux-rd bench` flag, each
repeatable and in the `=` form (the value starts with `-`). Only an allowlist passes
(`--resolution-ladder`, `--max-qp N`, `--max-kbps N`; `--caps LIST`); anything else
is refused. Both lists go into every output line and the table headers, so `compare` shows what
differed. A head run with the resolution ladder on:

```
scripts/screen-share-vs.py run ... --label ladder --out ladder.jsonl \
  --host-arg=--resolution-ladder --host-arg=--max-qp=40 --host-arg=--max-kbps=1000 \
  --viewer-arg=--caps=video.scaled
```

The shared Mac runs the rig (`screen-share-vs.py rig`) inside an app that holds Screen Recording
and Accessibility. The Apple leg is a headless RFB client: it never opens Screen Sharing.app or
any window. A row that cannot be measured yet prints null with its reason under the table; the
script's docstring maps each row to today's timing log and to the per-frame stage ledger.

## Linux desktop host (shared with cmux on a Mac)

A Linux desktop joins the person's devices and shows up on the Mac's Screen Sharing page
like a shared Mac. On the desktop, as the user who is signed in to its graphical session:

```
cmux-rd linux-host enable [--view-only]
install -Dm644 systemd/cmux-screen-host.service ~/.config/systemd/user/cmux-screen-host.service
systemctl --user daemon-reload && systemctl --user enable --now cmux-screen-host.service
```

- `enable` signs in once: it prints a sign-in link (and opens it when the desktop has a
  display), which you can open in any browser, on this machine or another; once you confirm,
  it continues. `--stack-token-file PATH` (a file only this user can read, mode 0600, or `-`
  for stdin) passes a cmux access token instead. No token is stored. It creates this desktop's device keys in
  `~/.config/cmux/screen-host/` (0700; files 0600), registers it as a `linux` device, anchors
  it, downloads Cisco's OpenH264 into the per-user data directory (the encoder, never bundled;
  the file `cmux-rd openh264-install` writes) and turns sharing on. The anchor lets the host renew its own session with its device key
  for 30 days; after that, `share on` again (it signs in the same way).
- Consent: this desktop joined your own account, so your devices view and control it with no
  prompt here (the hub serves a device of the same account at once; `enable --view-only` keeps
  control off). A viewer you set to Ask on the hub still asks: `cmux-rd linux-host requests` lists
  those requests (also logged: `journalctl --user -u cmux-screen-host`), `approve SESSION [--always]
  [--scope view|full]` or `deny SESSION` answers. The host never answers one by itself. A View
  session applies no input. On Wayland, `enable` asks the ScreenCast portal for its grant once and
  keeps the restore token, so later sessions start with no portal dialog.
- The unit is a user unit: it must run in the seat0 session's user manager, with that
  session's D-Bus and `DISPLAY`/`XAUTHORITY`/`XDG_SESSION_TYPE` (see the unit file).
- Capture: X11 sessions stream the X screen (`--display`, else `$DISPLAY`, else `:0`;
  `--xauthority` or `XAUTHORITY`). A Wayland session (`XDG_SESSION_TYPE=wayland`) uses the
  portal backend (xdg-desktop-portal ScreenCast and PipeWire, feature `portal`); a build
  without it ends those sessions with "portal capture not built in". `--capture x11|portal`
  overrides.
- Wayland grant: `enable` asks the portal once, while the person joining is at the screen
  (its dialog), and saves the restore token in `~/.config/cmux/screen-host/`; every later
  share restores it with no dialog. Unless `--view-only`, it asks for a RemoteDesktop
  session (keyboard and pointer too) where the portal can keep that grant (RemoteDesktop
  version 2 or later), so control works on Wayland; otherwise the desktop is shared view
  only. A grant the person revoked makes the next share show the dialog once, then it is
  saved again. `cmux-rd linux-host grant [--control]` makes the grant again by itself.
- Machine join: `cmux-rd linux-host enable --non-interactive` is the one command the join
  runs after the acpmux join, often over ssh. It takes no account token and opens no
  browser: no person's credential is kept on a joined machine. It finds the desktop
  through logind and sets up capture. A Wayland desktop gets the one grant above (the
  dialog stays up a minute at most), and "this desktop's screen-share portal can't
  remember a grant; each share will ask once on this machine" or "view only: this desktop
  has no remote-input portal" when its portal cannot keep one. With no graphical session
  it sets up an Xvfb display cmux owns (`cmux-screen-display.service`, :99 or the next free
  one) and says "no graphical session on this machine; shares use a virtual display at :N,
  started when one is needed". The host starts it for a share or `linux-host display`
  (an app launch), and stops it after 10 minutes with no share and no app window on it.
  A desktop still enabled (anchored), or a machine joined to cmux, gets the host unit
  installed, enabled and started, with lingering for a virtual display. A joined machine
  signs itself in with its machine credential (`$ACPMUX_HOME/machine-credential.json`, the home of the acpmux that runs it,
  `POST /v1/auth/machine`), registers, and turns sharing on, so nobody does anything on it.
  Any other machine prints one `not_installed:` line. It never fails the join.
- Viewers: cmux on a Mac (cmux.rd/1). The iPhone's WebRTC viewer is not served by this host
  yet; its session ends with that reason.
- Relays the person added by hand are sealed to the device's agreement key and not opened
  yet: the host uses the hub's ICE servers.

## Windows PC on the device hub

A Windows PC joins the person's devices as a `windows` device and serves viewing sessions
with the Linux host's hub client, consent and session code (`src/screen_host/`). In the
signed-in user's session (not a service):

```powershell
cmux-rd windows-host enable --stack-token-file $env:APPDATA\cmux\stack-token [--allow-control]
cmux-rd windows-host run
schtasks /Create /SC ONLOGON /TN cmux-screen-host /TR "C:\path\cmux-rd.exe windows-host run"
cmux-rd windows-host status
```

- `enable` registers, anchors, turns sharing on and downloads Cisco's OpenH264. Control
  (SendInput) needs `--allow-control`; without it every session is view only.
- `run` holds the hub socket and serves each approved session through a `cmux-rd serve`
  child (`src/windows_serve.rs`: GDI capture, OpenH264, the secure link). Viewers the person
  has not allowed wait for `requests`, `approve SESSION [--always]` or `deny SESSION`.
- Keys and account in `%APPDATA%\cmux\screen-host\`, run state in
  `%LOCALAPPDATA%\cmux\screen-host\run\`.
- `cmux-rd windows-serve-selftest [--scope view|control]` runs one session against a viewer
  on the same PC, no hub. What Windows itself blocks (UAC, lock screen):
  `docs/device-hub/windows-host.md`.

## Build

### Observe a viewer's presented marker (macOS bench build)

`observe` watches the **viewer display**, independently of the remote protocol.
It measures from posting a key/click to the viewer PID until ScreenCaptureKit's
display timestamp for the exact next marker counter. This is a compositor
measurement, not physical glass-to-glass: panel scanout and pixel response are
excluded. It is also distinct from `bench`, which ends at decode.

```
cmux-rd observe --pid VIEWER_PID --window CGWINDOW_ID --display main \
  --marker-origin X,Y --cell-size N --at CLICK_X,CLICK_Y \
  --input key --samples 200 --timeout-ms 1000 --seed 1
```

Use a dedicated viewer Mac with Screen Recording and Accessibility already
granted. Open the intended connection in its real viewer, verify its remote
host and quality setting, and focus the marker on the remote host. Run `key`
and `click` separately; clicks go to the marker's gray pad, outside its 20
black/white cells. This command does not open connections, choose quality,
grant permission, or change focus. Its process-targeted events may be refused
by a viewer; that is a failed run, not a latency result.

All coordinates and cell size are **viewer capture pixels**, not remote pixels
or macOS points. The capture retains the engine's fit-to-3840×2160 behavior;
inspect the viewer at that scale and supply an integer cell width of at least
two pixels. The JSON receipt records capture dimensions, global display bounds
in points, marker coordinates and requested capture refresh rate. Use the same
display, geometry and observer settings for every contender. The explicit
window ID and PID must own the visible marker centers and input point before
each input and after each response; another window from the same process does
not qualify. This is an isolation check, not proof of remote authentication:
the run's GUI evidence must establish the connection identity separately.

Success writes `cmux.presented-marker/1` JSON with every latency in microseconds
and nearest-rank p50/p95 in milliseconds. Each input has a deadline. Stale
frames are ignored, wrong guards or skipped counters fail or time out, and an
incomplete run emits no success percentile. Seeded 25–75 ms stimulus intervals
avoid locking input to one refresh phase. Tests named `observe_` cover counter
wrap, stale timestamps, scaled marker decoding, occlusion and quantiles.

The current passive `bench`/WebRTC test viewers do not present windows, so this
observer must be paired with a real renderer before comparing them to Apple.
Native compilation and unit tests alone do not validate presentation latency.

For passive presented-frame samples, use the source marker mode with an explicit start signal:

```
cmux-rd observe --mode passive --pid VIEWER_PID --window CGWINDOW_ID \
  --marker-origin X,Y --cell-size N --expected-nonce 00112233445566778899aabbccddeeff \
  --start-file /tmp/scene-ready \
  --duration-s 10 --interval-ms 1000
```

The observer decodes the marker on every complete ScreenCaptureKit callback into a bounded queue,
reports callback count separately from distinct marker counters, accepts counter gaps as dropped
frames, and reports repeats, invalid samples, and queue overflow. The optional expected nonce is
eight rows below the counter row, each row using the same 16-bit LSB-first cells and `1010` guard;
the eight little-endian words form 16 bytes rendered as canonical lowercase hex. Its
`cmux.presented-marker-series/2` receipt measures the compositor display timestamp to callback
arrival boundary and requires the exact visible PID/window geometry. With an expected nonce,
`host_identity_verified` and `nonce_observed` are true only for matching samples; marker-only runs
remain false. Because the observer seeds a baseline before the start-file signal,
`first_changed_marker_ms` is change-after-signal timing; `session_ttff_ms` remains null until an
external session-start timestamp is bound.

For selected-process CPU, run the macOS bench command during the measured phase:

```
cmux-rd observe-cpu --pid VIEWER_PID --duration-ms 1000
```

The `cmux.process-cpu-interval/1` receipt divides the selected process's user plus system CPU
nanosecond delta by the actual monotonic sample interval. Percentages use one CPU core as 100%,
so a multithreaded process can exceed 100%. Process start timestamps reject PID reuse; unavailable
samples have a null percentage and an explicit reason. `viewer` is the selected process and
`observer` is this CPU sampler, not a separate ScreenCaptureKit observer. Sample that process by
its own PID to keep capture overhead separate. `host_cpu_pct` stays null: the harness must identify
and sample the remote host process separately, with the same phase boundaries. This standalone
command is not yet connected to the comparison target adapters.

This crate is its own Cargo workspace (excluded from the cmux-tui workspace) because it
builds C code: openh264 from source (bench builds), and x264 only with `--features x264`. Build it on Linux (a Testbox or a
VM), never on a Mac: `cargo build --release`.

### Stage ledger: where each frame's milliseconds go (`cmux.rd-stage-ledger/1`)

Decision D8 of cmuxterm-hq `docs/design/screen-share-under-100ms.md`. A viewer that offers
cap `ledger` (and `clock`, so its times convert to the host's) gets, after each frame's last
shard, a `FrameTimes` datagram (kind 12, cmux-rd-proto `frame_times.rs`) with the host's times
for that frame: display time (ScreenCaptureKit's, 0 where the capture backend has none), encode
start, bitstream ready, first and last datagram handed to the carrier. The viewer adds first
shard, last shard (the frame became decodable), released, decoded and presented
(cmux-rd-core `ledger.rs`). A viewer that does not offer the cap gets nothing new.

`cmux-rd bench` prints the run's table as `stage_ledger` in its report line, and the app logs
it every 5 s (`remote-view-rd`, "stage ledger: ..."). One JSON object, all times in ms on the
host's clock:

```json
{"schema":"cmux.rd-stage-ledger/1","clock":"host monotonic","frames":N,"frames_with_host_times":N,
 "offset_us":-1234,"received_mbps":14.2,
 "stages":[{"stage":"Capture","from":"display time","to":"encode start","budget_ms":8.000,
            "n":N,"p50_ms":3.1,"p95_ms":6.0,"reason":null}, ...],
 "display_to_decoded":{"n":N,"p50_ms":..,"p95_ms":..}}
```

`stages` always has these twelve rows, in order: Input, Screen, Capture, Encode, Send,
Network, Transport, Recovery, Reassembly, Decode, Present, Total. They are the ten rows of the
design's budget table plus Network split in two right after it: Transport + Recovery = Network
for every frame. A row with no samples has `n: 0`, null percentiles and a `reason`:

| Stage | From, to | Filled by |
| --- | --- | --- |
| Input | viewer key down to host inject | the fleet harness (observer input receipt + host `inject_us`) |
| Screen | inject to display time | the fleet harness (host `inject_us` + `shown_us`) |
| Capture | display time to encode start | host |
| Encode | encode start to bitstream ready | host |
| Send | bitstream ready to last datagram sent | host |
| Network | last datagram sent to last shard received | host + viewer (needs the clock offset) |
| Transport | first datagram sent to first shard received: the path's one-way delay | host + viewer (needs the clock offset) |
| Recovery | arrival spread (first to last shard) minus send spread (first to last datagram): time lost to retransmits, waiting for parity, jitter and queueing; can be negative when the path squeezes the burst | host + viewer (one clock each) |
| Reassembly | last shard to frame released | viewer |
| Decode | released to decoded | viewer |
| Present | decoded to on glass (drawable presented time) | the app; `cmux-rd bench` has no renderer |
| Total | display time to presented | the app; the bench reports `display_to_decoded` instead |

Send ends when the last datagram is handed to the carrier: on a link carrier that is the link
thread's queue, not the socket. `CMUX_RD_TIMING_LOG` lines carry the same host times per frame
(`release_us` is the gate's release, `capture_us` the frame's `t_capture_us`, `encode_start_us`,
`encoded_us`, `first_sent_us`, `sent_us`), for the harness to join with its observer's input and
presented-marker receipts.

## Release

`.github/workflows/cmux-rd-release.yml` publishes a GitHub release `cmux-rd-vX.Y.Z` (tag on
feat-cmux-next, matching this crate's version) with
`cmux-rd-X.Y.Z-x86_64-unknown-linux-gnu.tar.gz` and `checksums.txt` (sha256). It builds with
`--no-default-features --features openh264,link` (no bench, no x264) through cargo-zigbuild at
the glibc 2.31 floor. The archive holds `bin/cmux-rd`, `LICENSE` (GPL-3.0-or-later) and
`THIRD_PARTY_LICENSES.md`, which `scripts/release.py notices` writes from the build's exact
`cargo tree`; no H.264 codec is in it.

## Licensing and codecs

- cmux-tui, including this crate, is GPL-3.0-or-later (Lawrence, 2026-10-03). x264 waits
  for Lawrence's legal decision on H.264 patent royalties; the default encoder is Cisco's
  OpenH264 binary downloaded from Cisco at run time (Cisco pays the royalties), feature
  `openh264` (on by default, `--codec openh264`, below). x264 is opt-in only
  (`--features x264`, needs a static `libx264.a`, Ubuntu's `libx264-dev`) and never in a
  release build.
  x264 (r3108, 31e19f9) and OpenH264 2.6.0 are listed in THIRD_PARTY_LICENSES.md.
- x264 (opt-in) runs `ultrafast` with `zerolatency` (no B-frames, no lookahead,
  scene-cut off, infinite GOP, ABR with a one-frame VBV that follows congestion control).
  Measured on 1080p loopback (Testbox): text scroll 39 fps, G2G p50 9 ms, 6 Mbit/s;
  marker G2G p50 3.5 ms. openh264 in screen mode reached 28 fps / p50 38 ms on text and
  camera mode collapsed (2.3 fps).
- openh264 with `--codec openh264` (`--content screen|camera`) uses Cisco's prebuilt
  binary only. Cisco's royalty-free H.264 patent license covers only a binary that each
  user downloads from Cisco, so it is never bundled in an app, image or release artifact,
  and a shipped host never builds it from source (the source build exists only in bench
  builds and in the test-only cmux-remote-browser-testhost).
  - Install: `cmux-rd openh264-install [--dir PATH]` is the host enable flow's step. It
    downloads Cisco's 2.6.0 file for this platform from `https://ciscobinary.openh264.org/` (HTTPS, certificate verified)
    (the URLs in `cmux_encode::openh264::CiscoBinary`), decompresses the bzip2 file, and
    keeps it only when the library's SHA-256 matches the pinned value (nothing is written
    otherwise). A session never downloads.
  - Storage: one file per user, `<data dir>/cmux/openh264/<Cisco file name>`, where the
    data dir is `$XDG_DATA_HOME` or `~/.local/share` on Linux and `%LOCALAPPDATA%` on
    Windows; on macOS it is `~/Library/Application Support/cmux-next/openh264`, outside
    classic cmux's folder. It is written to a temporary file,
    flushed and renamed, so a reader never sees a partial file.
  - Loading: `--openh264-lib PATH`, else the installed copy. `load_verified` hashes the
    file again and only then loads it with `dlopen`; a file with another hash is refused.
  - x264 carries no patent coverage; it ships to no one until Lawrence decides (D-RD1).
- The encoder sits behind one trait (`encoder::H264Encoder`). Hardware encoders (VA-API,
  NVENC, and VideoToolbox on macOS hosts) are later implementations of the same trait.
- `--profile high` (default) is for the macOS pane's VideoToolbox decoder; the Linux bench
  decoder (openh264) needs `--profile baseline` on the host (scripts/loopback-bench.sh sets it).
- `--encode-profile ultra` (`host` and `serve`; opt-in, standard is the default) stops saving
  bandwidth on a fat link: frames at the viewer's rate (else the display's refresh) up to 120 fps,
  a 150 Mbps ceiling unless `--max-kbps` names one. On VideoToolbox it holds frame rate first:
  it runs the regular hardware encoder instead of the low-latency one (whose realtime encoder
  refuses DataRateLimits and drops frames instead), and each frame gets one frame interval's
  share of the target (DataRateLimits) but never more than 3 bits per pixel (about 0.78 MB at
  1080p), with no QP ceiling and no QP floor (`CMUX_RD_VT_ULTRA_MIN_QP` sets one), so extra
  rate buys fps before per-frame quality. A keyframe alone gets QP 30 or more. One frame
  interval after the screen goes still, one refinement frame takes up to four frame budgets.
  H.264 level 5.2 still bounds the frame rate at large sizes
  (`mac::encoder_fps`): a 4K display encodes at most about 64 fps in H.264.

## Upstream media (development)

A viewer's microphone, camera or screen share reaches the host only when the host offers
the `up_media` cap, and it offers it only with a sink. The desktop has no virtual
microphone or camera sink yet (audio: cx-wb5.19), so by default the host offers none and
refuses `stream_open` with `caps`. `--upstream-record DIR` (development only) records each
upstream stream to its own owner-only file in `DIR`: video as the raw Annex-B stream
(`up-<ms>-<stream>.h264`), audio as Opus packets each after a little-endian u16 length
(`up-<ms>-<stream>.opus-packets`). On every stream close the host logs one JSON line,
`{"upstream_recorded": {stream, kind, path, frames, bytes, fnv1a, error}}`. `frames` and `bytes` count what arrived (after a write error, more than was written). The directory must be the user's own with mode 0700. One session records at most `--upstream-record-max-mb` (default 1024) and 64 files; past that it stops writing and refuses new streams. The files hold
the viewer's microphone and screen; never enable this on a shared machine.

`cmux-rd bench --upstream mic|camera|screen` sends synthetic frames upstream through the
same sender as the viewer app (`cmux-rd-core::upstream`) and reports the frames sent and
acknowledged and the FNV-1a hash of the sent bytes. `scripts/upstream-loopback.sh` runs
both carriers against a recording host and a default host, and passes only when every
sent frame was recorded whole and in order and the default host refused with `caps`.

## Security: Cloud machines (production)

```
cmux-rd host --listen-systemd --peer-uid 1000 --display :99 --xauthority /run/cmux-rd/Xauthority-99 --codec openh264 [--idle-exit-s 120]
```

This is the production mode on NEXT Cloud machines. The viewer is the machine owner's Mac app;
its rd pane dials the machine over the carrier (`cmux carrier dial --service desktop`), and the
machine's carrier server (`cmux carrier serve`, running as the work user `cmux`, uid 1000) admits
it only on the owner's grant for service `desktop`. Only then does the server connect to the host.

- No network listener. The host takes its one listening socket from systemd
  (`cmux-agent-rd.socket`: `/run/cmux-rd/desktop.sock`, `SocketUser=root`, `SocketGroup=cmux`,
  `SocketMode=0660`, `/run/cmux-rd` mode 0711), as fd 3 with `LISTEN_FDS=1` and `LISTEN_PID` set to the
  host's pid. Without them it refuses to start, and it refuses any passed fd that is not a
  listening Unix stream socket. There is no TCP or UDP port; `--token-fd`, `--bind`, `--port`,
  `--single-tenant-overlay`, `--upstream-record` and `--browser` are refused in this mode.
- Only the receiver's uid connects. `--peer-uid N` is required; every accepted connection's
  `SO_PEERCRED` uid must equal it (1000, the work user the link receiver runs as), or the
  connection is closed before any byte is read. Other users can neither open the socket (root,
  group `cmux`, 0660) nor pass the uid check.
- What this does not hold against: the agent runs as that same user `cmux` (and has passwordless
  sudo, `web/services/vms/images/workUser.ts`), so it can reach the socket; the uid check keeps
  out other users only. The boundary that holds against
  other people is the link admission (the owner's one-time token). Taking sudo away from agent
  sessions is a separate decision.
- The principal is the machine owner. The link already admitted the owner, so the hello's token
  and its user, class and interactive claims are not used: the session's principal is the owner,
  a person at the app (`--owner`, default `owner`). The hello's `start` mode chooses `view` or
  `control`; `control` sends XTest input through the XI2 master `cmux person`, so the agent's
  computer use keeps `:99`'s core pointer and keyboard. The master exists only while the person
  acts: made on their input, removed after 3 s with no input and nothing held (Chromium takes
  keys from one master keyboard only, so the agent's keys into Chrome are lost while it exists)
  and when control ends, and made again where the person's pointer was. One a crashed host left
  is replaced; one another live host lists in `_CMUX_RD_PERSON_HOSTS` is shared, never removed
  under it. A person's press waits (at most 2 s from its arrival) while the core pointer holds a
  button. The root property `_CMUX_RD_PERSON` exists exactly while the master does and names the
  window under the person's pointer, so an agent can wait while it exists before typing into
  Chromium (see `src/inject.rs`).
- No UDP port in the hello. A hello that asks for one is refused (`StreamCarrierOnly`).
- Media may move to a UDP link (cap `link.udp`, `src/hybrid.rs`). When the hello offers the cap,
  the welcome lists it and caps `max_datagram` so a sealed datagram fits the link. The viewer
  then sends `link_offer` (its cmux-rd-link key, a prologue and candidates) on the stream. The
  host starts a Noise_XX link (one UDP socket, port picked by the kernel, reflexive candidate
  from `--link-stun HOST:PORT,...`), answers `link_answer` with its own key, and sends its
  candidates as `link_candidate`. Both keys cross the carrier's admitted stream, so the link
  trusts only what the carrier trusts. A packet that is not that peer's Noise traffic is dropped.
  Media datagrams use the link while one of its paths answers (`link_state up`). Before that,
  and whenever no path answers, they stay on the stream (`link_state` down with a reason).
  Control never leaves the stream. `--no-udp-link` turns the cap off.
- The service runs as its own system user (`cmux-agent-rd.service`, `User=cmux-rd`, not in group
  `cmux`), reads the X cookie from `--xauthority` (set as `XAUTHORITY`), and exits after
  `--idle-exit-s` seconds (default 120) with no connection; the socket unit starts it again on the
  next one.
- OpenH264 is installed by `cmux-rd openh264-install` as `cmux-rd` into its own state directory;
  it is never in the release archive (`.github/workflows/cmux-rd-release.yml`).

## Security (phase 1, development)

- Per-launch session token: the host needs `--token-fd N`, an inherited pipe from its parent
  (the cmux daemon) that carries a 256-bit token; no file, environment variable or argv value
  holds it. A hello without the exact token is refused before any session or frame
  (constant-time compare). The daemon releases the token only through `secret.release` to
  the `frontend` actor (the native app's viewer pane); terminal and agent actors are refused
  (P8 slice 3). Until that lands the host is development only and the pane is not in
  Release builds.
- The parent writes the 64 hex characters into the pipe; the host reads exactly those (no
  wait for end of file) and refuses a regular file. On loopback the token crosses only the
  local socket; with `--single-tenant-overlay 1` it relies on the overlay's encryption.

- Development only. By default the host binds loopback (`--bind 127.0.0.1`) and refuses every
  non-loopback peer before it reads the hello. Reach it through SSH or a tunnel. A private
  single-tenant overlay (RFC 1918, CGNAT or ULA address) needs the explicit
  `--single-tenant-overlay 1`; public addresses are always refused.
- Loopback trusts every process on the same machine: on a machine that also runs agents
  (for example a cloud dev VM), any local process can connect and claim the owner. Until
  the link token exists, run the host only on a machine with no other users or agents.
- Known gap until the overlay link token (lane 12) replaces them: the host trusts the
  principal claims in the `hello`. Every process that can reach the bind address can claim
  the owner and an interactive person, including agent VMs on a team VPC and every tailnet
  node when the address is in 100.64/10. Run phase-1 hosts on loopback (reached through SSH
  or a tunnel) or on a single-tenant overlay only.
- For honest claims, admission, consent, grants and the input gate come from
  `cmux-rd-core::session`: only the host's owner (or a granted principal) may view; only a
  person's client may control; agent principals never control.
- UDP datagrams are accepted only from the viewer's exact socket (address and port named
  in the hello); a viewer behind NAT must use the stream carrier. Viewers send feedback at
  least once per second on both carriers; three silent seconds end the session.

### Windows loopback performance proof

The Windows selftest workflow builds with `--release --no-default-features --features bench`
and runs two trials at each physical desktop resolution, 1920×1080 and 3840×2160:

```powershell
.\target\release\cmux-rd.exe windows-selftest --loopback 1 --width 1920 --height 1080 --duration-s 10 --codec openh264
```

Run `.github/scripts/cmux-rd-motion.ps1 -IntervalMs 16 -FullScreen` in a separate
owned process to keep the desktop changing. The benchmark temporarily sets the
desktop resolution and restores it on exit. A driver rejecting optional 4K with
`DISP_CHANGE_BADMODE` reports `4K: not measured, no display mode` and succeeds
without metrics. Missing 1080p or any capture/transport/viewer failure still fails.
It uses the selected production capture backend, encoder, media engine, stream framing and
feedback path over TCP loopback. The receiver reassembles and decodes the stream,
presents it in a visible GDI window and checks its center pixel with `GetPixel`.
At least two distinct presented colors are required. No tailnet or credentials
are needed. This measures a local Windows viewer, not a Mac or iOS viewer.

JSON reports `first_frame_ms` from connection start to the first presented pixel,
`fps` over the steady interval after a one-second warmup, and nearest-rank
`p50`/`p95` milliseconds for capture (including copy and change detection),
conversion, encoding, decoding, and presentation (including RGB conversion and
readback). Stage distributions include startup; sample vectors cap at 8192.
Duration is bounded to 2–30 seconds, sockets have timeouts, and the host and
viewer each have a deadline. Keep this harness and motion source unchanged
when comparing before/after optimization results.

The Windows host prefers DXGI Desktop Duplication and falls back to GDI if the
primary output cannot be duplicated or access is lost. `--capture gdi` and
`--capture dxgi` select a backend explicitly; forced DXGI fails by HRESULT rather
than measuring GDI under the DXGI name. The workflow runs both through the same
loopback harness and motion source. JSON `capture_details` identifies the backend,
fallback reason, acquired frames and copied bytes.

Duplication retains one CPU BGRA surface and one staging texture. It copies dirty
rectangles and move destinations from the complete current desktop texture,
respects row pitch, and uses a full copy for initialization or fragmented damage.
It avoids full-frame hashing. Encoding still converts the full frame, so no
unchanged-region conversion claim is made. An unchanged acquisition reuses the
last surface when feedback requests a frame. Memory is bounded to a 256 MiB CPU
surface plus the matching staging texture and at most 1 MiB metadata per list.
The existing capture surface excludes a separately supplied hardware cursor;
this preserves the GDI BitBlt behavior. Rotated outputs retain the GDI path.
