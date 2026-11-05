# cmux-rd-host

The host engine of the cmux remote desktop and its bench client: on Linux a virtual X display
such as Xvfb on servers and Cloud VMs (phase 1); on macOS the Mac's own display through
ScreenCaptureKit, VideoToolbox and CGEvent (`plans/cmux-next/remote-desktop-mac-host.md`). Design and decisions:
`plans/cmux-next/remote-desktop.md`. Wire format: `cmux-rd-proto`. Pure logic (FEC,
packetizer, reassembly, frame gate, congestion control, input, sessions and access
policy): `cmux-rd-core`.

```
cmux-rd host    --listen-systemd --peer-uid 0 [--display :99] [--xauthority PATH] [--idle-exit-s 120]   (Cloud machines; below)
cmux-rd host    --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99] [--port 4103] [--codec openh264] [--upstream-record DIR [--upstream-record-max-mb 1024]]
cmux-rd bench   --addr HOST:4103 --token-fd N [--carrier udp|stream] [--samples 300] [--user USER] [--upstream mic|camera|screen --upstream-frames 100]
cmux-rd testapp --display :99 --workload marker|text|motion|idle
```

## macOS host

```
cmux-rd host --owner USER --token-fd N [--display main|INDEX] [--max-fps 60] [--profile high|baseline]
```

The codec is always `videotoolbox`, fed the captured IOSurface with no copy. The process, or
the app that started it, needs Screen Recording and Accessibility.
`scripts/mac-host-run.sh BIN_DIR STATE_DIR [--motion]` starts the host and the glass-to-glass
marker app (`scripts/mac-marker`, build with `swiftc -O`) on a test Mac; `cmux-rd bench`
from another Mac then measures latency (`--snapshot FILE.ppm` keeps the newest decoded frame).
Build on a fleet Mac: `cargo build --release --no-default-features --features bench`.

## Build

This crate is its own Cargo workspace (excluded from the cmux-tui workspace) because it
builds C code: openh264 from source (bench builds), and x264 only with `--features x264`. Build it on Linux (a Testbox or a
VM), never on a Mac: `cargo build --release`.

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
    data dir is `$XDG_DATA_HOME` or `~/.local/share` on Linux, `~/Library/Application
    Support` on macOS and `%LOCALAPPDATA%` on Windows. It is written to a temporary file,
    flushed and renamed, so a reader never sees a partial file.
  - Loading: `--openh264-lib PATH`, else the installed copy. `load_verified` hashes the
    file again and only then loads it with `dlopen`; a file with another hash is refused.
  - x264 carries no patent coverage; it ships to no one until Lawrence decides (D-RD1).
- The encoder sits behind one trait (`encoder::H264Encoder`). Hardware encoders (VA-API,
  NVENC, and VideoToolbox on macOS hosts) are later implementations of the same trait.
- `--profile high` (default) is for the macOS pane's VideoToolbox decoder; the Linux bench
  decoder (openh264) needs `--profile baseline` on the host (scripts/loopback-bench.sh sets it).

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
cmux-rd host --listen-systemd --peer-uid 0 --display :99 --xauthority /run/cmux-rd/Xauthority-99 --codec openh264 [--idle-exit-s 120]
```

This is the production mode on NEXT Cloud machines. The viewer is the machine owner's Mac app;
its rd pane dials the owner's Native link with service `desktop`, and the machine's root link
receiver admits it exactly as it admits `ssh` and `daemon`: a platform-minted, one-time,
owner-only link token naming service `desktop`, verified locally (`NativeTokenVerifier`, replay
history, the receiving policy's peer services). Only then does the receiver connect to the host.

- No network listener. The host takes its one listening socket from systemd
  (`cmux-agent-rd.socket`: `/run/cmux-rd/desktop.sock`, `SocketUser=root`, `SocketMode=0600`,
  `/run/cmux-rd` mode 0710 `root:cmux-rd`), as fd 3 with `LISTEN_FDS=1` and `LISTEN_PID` set to the
  host's pid. Without them it refuses to start, and it refuses any passed fd that is not a
  listening Unix stream socket. There is no TCP or UDP port; `--token-fd`, `--bind`, `--port`,
  `--single-tenant-overlay`, `--upstream-record` and `--browser` are refused in this mode.
- Only the receiver connects. `--peer-uid N` is required; every accepted connection's
  `SO_PEERCRED` uid must equal it (0, the root receiver), or the connection is closed before any
  byte is read. A non-root process, the agent's user `cmux` included, can neither open the socket
  (root only, 0600) nor pass the uid check.
- What this does not hold against: on Cloud machines the agent user `cmux` has passwordless sudo
  (`web/services/vms/images/workUser.ts`), so an agent that uses sudo is root and can reach the
  socket. The uid-0 check keeps out non-root processes only. The boundary that holds against
  other people is the link admission (the owner's one-time token). Taking sudo away from agent
  sessions is a separate decision.
- The principal is the machine owner. The link already admitted the owner, so the hello's token
  and its user, class and interactive claims are not used: the session's principal is the owner,
  a person at the app (`--owner`, default `owner`). The hello's `start` mode chooses `view` or
  `control`; `control` sends XTest input to `:99`'s core pointer and keyboard.
- The stream carrier only. A hello that asks for UDP is refused (`StreamCarrierOnly`).
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
