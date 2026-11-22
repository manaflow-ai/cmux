# cmux-mesh-agent

Device agent for the cmux mesh experiment (M1b, M2, M3). It enrolls a device's
WireGuard public key with a mesh, rotates that key, and tests one userspace
WireGuard tunnel to the provider gateway: `keygen`, `install-keygen`, `enroll`,
`rotate`, `peers`, `tunnel`, `up`, `ping`, `tcp`, `probe`. No root, no utun, no Network
Extension, no host route change.

```sh
cmux-mesh-agent keygen --key-file device.key           # prints the public key only
cmux-mesh-agent install-keygen --out install.key       # prints the install public key only
CMUX_VM_API_URL=https://… CMUX_VM_API_KEY=… \
  cmux-mesh-agent enroll --key-file device.key --install-key install.key \
    --mesh mesh_… --name laptop --out mesh.json
CMUX_VM_API_URL=https://… CMUX_MESH_ENROLL_CODE=mec_… \
  cmux-mesh-agent enroll --key-file device.key --install-key install.key \
    --mesh mesh_… --name laptop --out mesh.json        # one-time code, no API key
CMUX_VM_API_URL=https://… CMUX_VM_API_KEY=… \
  cmux-mesh-agent rotate --config mesh.json --key-file device.key \
    --install-key install.key --new-key-file device.next.key
CMUX_VM_API_URL=https://… cmux-mesh-agent peers  --config mesh.json --install-key install.key   # no API key: signed
CMUX_VM_API_URL=https://… cmux-mesh-agent tunnel --config mesh.json --install-key install.key   # no API key: signed
cmux-mesh-agent ping  --config mesh.json --key-file device.key vm_… -c 5
cmux-mesh-agent tcp   --config mesh.json --key-file device.key 10.128.16.5 8080 --send hello
cmux-mesh-agent probe --config mesh.json --key-file device.key vm_… 8080 --interval-ms 50 --duration-s 30
```

The handshake time goes to stderr as `{"event":"handshake","ms":…}`; results go
to stdout as one JSON line each. `probe` attempts overlap (one starts every
interval, each times out after `--attempt-timeout-ms`, default 300), so its lines
can come out of `t` order; sort by `t`.

## Install key, enrollment, and rotation

The install key is an ECDSA P-256 key in a 0600 file (base64 of the 32-byte
scalar). It signs every enrollment and rotation; its public key goes on the
wire as base64 of the 65-byte uncompressed point. The signed message is eight
lines joined by `\n` (`cmux-mesh-v1`, purpose `enroll` or `rotate-key`, mesh or
device id, WireGuard key being registered, install public key, device name or
empty, signedAt in unix ms, a 22-character base64url nonce); the signature is
base64 of the 64-byte `r||s`. `src/install.rs` has the exact format and
`tests/install.rs` golden vectors. The server accepts signedAt within 120 s of
its clock and refuses a replayed message.

`enroll --code` (or `$CMUX_MESH_ENROLL_CODE`, which keeps the code out of
argv) posts to `/v1/meshes/{mesh}/device-enrollments` with no Authorization
header; the code is never printed. Without a code it posts to
`/v1/meshes/{mesh}/devices` with `$CMUX_VM_API_KEY`.

`rotate` refuses an existing `--new-key-file`, writes the new 0600 key before
the request, posts `/v1/devices/{device}/rotate-key`, and on 200 replaces the
config atomically with the new tunnel (new `serverPublicKey`) and the new
device key. It never deletes the old key file; delete it after switching. It
prints `{"deviceId","sentAtMs","respondedAtMs","serverPublicKey","wgPublicKey"}`.
If the request fails the new key file stays; remove it before retrying.

## Device-signed requests (M3)

A device enrolled with a one-time code has no API key afterwards. Without
`$CMUX_VM_API_KEY`, `peers`, `tunnel` and `rotate` (and `ping`/`tcp`/`probe`
when they resolve a `vm_` id, with `--install-key`) sign the request with the
install key and post it with no Authorization header to
`/v1/devices/{device}/signed/peers`, `/signed/tunnel` or `/signed/rotate-key`.
The reads sign purpose `peers` or `tunnel` with the device id as target and
empty WireGuard-key and name lines; the body is only `signedAt`, `nonce`,
`signature`. The signature works only for this device, only once, and only
within 120 s; the server also refuses it once the API key or user that enrolled
the device (or made its code) is revoked or left the team. With
`$CMUX_VM_API_KEY` set the agent uses the key and the bearer routes, as before.
With neither, the command fails with `MissingCredential` before any request.

## Transport

boringtun 0.7 and smoltcp 0.14 directly, the versions cmux-tui pins. cmux-wg
was not reused: its public API (`WgNet`) gives TCP streams and UDP datagrams
only. It has no raw IP or ICMP path, and its smoltcp build has no
`socket-icmp`, so ICMP echo would need cmux-tui changes. The tunnel here is a
single-threaded poll loop (`src/tunnel.rs`) with no async runtime.

Build and test on Linux or macOS with `cargo test --locked`; this is its own
Cargo workspace with its own lockfile and toolchain.
