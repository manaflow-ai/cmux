# cmux-remote-host

cmux Remote on Windows and Linux: the host the cmux-tui daemon supervises over
`remote-host-v1`, its Computer Use worker on upstream Cua Driver
(trycua/cua `cua-driver-rs-v0.34.0`, commit `b0968e1b`), and the approval
contract. Design and packaging: `docs/cmux-remote.md` ("Windows and Linux") and
`docs/computer-use-approvals.md`.

Own Cargo workspace (excluded from `cmux-tui/Cargo.toml`) with upstream's
toolchain (`rust-toolchain.toml`). Never build it on a Mac:

```bash
cd cmux-tui/crates/cmux-remote-host
cmux-ci test --setup none --artifact /tmp/rh -- scripts/verify-linux.sh   # Linux tests, release build, Windows GNU check
rbx --lane <lane> --cwd cmux-tui/crates/cmux-remote-host -- cargo test --no-default-features   # protocol tests, no system libraries
```

| Path | What |
| --- | --- |
| `src/wire.rs` | the supervisor wire (shared with the Swift host) |
| `src/host/` | supervisor link, worker supervision, approval routing |
| `src/worker/` | Computer Use worker: admission, sessions, broker, Cua Driver |
| `src/approval.rs` | the approval request, canonical JSON, digest, answer rules |
| `src/approver.rs` | `RemoteApprover` (device hub) and local collectors |
| `src/collectors/` | polkit (Linux), Windows Hello |
| `src/config.rs` | the owner-only mode file |
| `dist/` | polkit policy, systemd user unit, Windows task, config example |
| `tests/conformance.rs` | replays `schemas/remote-host/v1-conformance.json` |
