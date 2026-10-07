# cmux-mesh-agent

Device agent for the cmux mesh experiment (M1b). It enrolls a device's
WireGuard public key with a mesh and tests one userspace WireGuard tunnel to
the provider gateway: `keygen`, `enroll`, `peers`, `up`, `ping`, `tcp`, `probe`.
No root, no utun, no Network Extension, no host route change.

```sh
cmux-mesh-agent keygen --key-file device.key           # prints the public key only
CMUX_VM_API_URL=https://… CMUX_VM_API_KEY=… \
  cmux-mesh-agent enroll --key-file device.key --mesh mesh_… --name laptop --out mesh.json
cmux-mesh-agent ping  --config mesh.json --key-file device.key vm_… -c 5
cmux-mesh-agent tcp   --config mesh.json --key-file device.key 10.128.16.5 8080 --send hello
cmux-mesh-agent probe --config mesh.json --key-file device.key vm_… 8080 --interval-ms 50 --duration-s 30
```

The handshake time goes to stderr as `{"event":"handshake","ms":…}`; results go
to stdout as one JSON line each. `probe` attempts overlap (one starts every
interval, each times out after `--attempt-timeout-ms`, default 300), so its lines
can come out of `t` order; sort by `t`.

## Transport

boringtun 0.7 and smoltcp 0.14 directly, the versions cmux-tui pins. cmux-wg
was not reused: its public API (`WgNet`) gives TCP streams and UDP datagrams
only. It has no raw IP or ICMP path, and its smoltcp build has no
`socket-icmp`, so ICMP echo would need cmux-tui changes. The tunnel here is a
single-threaded poll loop (`src/tunnel.rs`) with no async runtime.

Build and test on Linux or macOS with `cargo test --locked`; this is its own
Cargo workspace with its own lockfile and toolchain.
