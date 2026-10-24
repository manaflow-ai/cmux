# acpmux sandbox host prototype

`acpmux::sandbox_host` is the lifecycle seam for isolated agent runtimes. It keeps the controller API independent of the runtime: a local Linux process, gVisor/runsc, Firecracker, or Cloud Hypervisor can implement the same operations.

The checked in backend is intentionally provider free. `CommandSandboxBackend` starts a process in its own session, supports `SIGSTOP`/`SIGCONT` suspend and resume, records an immutable snapshot manifest, and forks a new process from that manifest. It never calls a cloud API. `Isolation::MicroVm` returns an explicit adapter-required error instead of silently running an unsandboxed process.

On a GCP Linux VM, this gives a safe smoke path:

```sh
cargo test --manifest-path cmux-tui/Cargo.toml -p acpmux sandbox_host --lib
```

A prepared image can opt into the gVisor path by setting `ACPMUX_SANDBOX_RUNSC` to the image's owner-only `runsc` binary and providing a bundle path in `SandboxSpec`. The host image and its GCP instance lifecycle remain provider-owned; this module only supplies the acpmux lifecycle contract.

Snapshot files contain the program, arguments, working directory, resource hints and environment key names. Environment values are removed before the atomic rename. A fork that needs credentials must call `fork_with_env` and supply short-lived values in memory. No secret is written to a snapshot or repository file.

A production microVM adapter should implement `SandboxBackend` around a provider API. Its `snapshot` should return a provider snapshot id, `fork_with_env` should inject credentials through the guest handoff, and `suspend` should map to the provider's pause or memory snapshot operation. The adapter should also report provider generation and interruption events so acpmux can fence a stale host.
