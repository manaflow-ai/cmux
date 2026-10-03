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
builds C code: openh264 from source, and optionally x264. Build it on Linux (a Testbox or a
VM), never on a Mac: `cargo build --release`.

## Licensing and codecs

- cmux-tui, including this crate, is GPL-3.0-or-later (Lawrence, 2026-10-03). The default
  build links x264 (GPL-2.0-or-later, compatible) statically; building needs
  `libx264-dev`.
- The default encoder is x264 `ultrafast` with `zerolatency` (no B-frames, no lookahead,
  scene-cut off, infinite GOP, ABR with a one-frame VBV that follows congestion control).
  Measured on 1080p loopback (Testbox): text scroll 39 fps, G2G p50 9 ms, 6 Mbit/s;
  marker G2G p50 3.5 ms. openh264 in screen mode reached 28 fps / p50 38 ms on text and
  camera mode collapsed (2.3 fps).
- openh264 (BSD-2-Clause, built from source) stays available with `--codec openh264`
  (`--content screen|camera`). Patent note: Cisco's royalty-free H.264 license covers only
  Cisco's prebuilt openh264 binary; neither a from-source openh264 nor x264 carries patent
  coverage, so shipping H.264 encoding to users still needs a patent decision (D-RD1).
- The encoder sits behind one trait (`encoder::H264Encoder`). Hardware encoders (VA-API,
  NVENC, and VideoToolbox on macOS hosts) are later implementations of the same trait.
- `--profile high` (default) suits hardware decoders such as VideoToolbox; the Linux bench
  decoder (openh264) needs `--profile baseline` on the host.

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
