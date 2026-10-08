# cmux-rd-host

The Linux host engine of the cmux remote desktop (phase 1: a virtual X display such as
Xvfb on servers and Cloud VMs) and its bench client. Design and decisions:
`plans/cmux-next/remote-desktop.md`. Wire format: `cmux-rd-proto`. Pure logic (FEC,
packetizer, reassembly, frame gate, congestion control, input, sessions and access
policy): `cmux-rd-core`.

```
cmux-rd host    --owner USER --token-fd N [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99] [--port 4103] [--codec openh264]
cmux-rd bench   --addr HOST:4103 --token-fd N [--carrier udp|stream] [--samples 300] [--user USER]
cmux-rd testapp --display :99 --workload marker|text|motion|idle
```

## Build

This crate is its own Cargo workspace (excluded from the cmux-tui workspace) because it
builds C code: openh264 from source (bench builds), and x264 only with `--features x264`. Build it on Linux (a Testbox or a
VM), never on a Mac: `cargo build --release`.

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

## Security (phase 1)

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
