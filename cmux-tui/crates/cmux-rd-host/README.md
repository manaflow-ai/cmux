# cmux-rd-host

The Linux host engine of the cmux remote desktop (phase 1: a virtual X display such as
Xvfb on servers and Cloud VMs) and its bench client. Design and decisions:
`plans/cmux-next/remote-desktop.md`. Wire format: `cmux-rd-proto`. Pure logic (FEC,
packetizer, reassembly, frame gate, congestion control, input, sessions and access
policy): `cmux-rd-core`.

```
cmux-rd host    --owner USER [--bind 127.0.0.1] [--single-tenant-overlay 1] [--display :99] [--port 4103] [--codec openh264]
cmux-rd bench   --addr HOST:4103 [--carrier udp|stream] [--samples 300] [--user USER]
cmux-rd testapp --display :99 --workload marker|text|motion|idle
```

## Build

This crate is its own Cargo workspace (excluded from the cmux-tui workspace) because it
builds C code: openh264 from source, and optionally x264. Build it on Linux (a Testbox or a
VM), never on a Mac: `cargo build --release`.

## Licensing and codecs

- The crate is MIT, like the rest of cmux-tui. The default build contains only MIT and
  BSD code: the H.264 encoder is openh264 (BSD-2-Clause), built from source.
- openh264 patent note: Cisco's royalty-free H.264 patent license covers only Cisco's
  prebuilt openh264 binary, downloaded separately to the user's machine. A build from
  source (this crate's default) does not carry that coverage. Shipping H.264 encoding to
  users needs either the Cisco binary path or a patent decision (remote-desktop.md D-RD1).
- x264 (GPL-2.0-or-later) is available behind the `x264` cargo feature, which is OFF by
  default. A binary built with it is a GPL binary. It is never part of shipped builds
  unless Lawrence decides on a GPL build of this binary. It is never linked into the MIT
  `cmux` binary: `cmux-rd` is a separate executable.
- The encoder sits behind one trait (`encoder::H264Encoder`), so the codec is a build
  feature and a `--codec` flag, not a code fork. Hardware encoders (VA-API, NVENC) are later
  implementations of the same trait.

## Security (phase 1)

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
