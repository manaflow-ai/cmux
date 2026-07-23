# Machine Agent Contract

The machine agent exposes one existing local cmux session to an authenticated cmux.cloud broker without a public listener. The selected session continues to speak mux protocol v9. The agent adds a separately versioned byte-stream tunnel around that session.

## Process and transport

The implemented entrypoint is:

```text
cmux-tui machine-agent [--session <name>] [--socket <path>]
  [--state <path>] [--cloud-host <host>] [--cloud-user <user>]
  [--cloud-port <port>] [--cloud-identity <path>]
```

Packaged builds expose the same mode as `npx cmux machine-agent`. The agent first probes the selected socket with `identify` and requires protocol v9. It then invokes OpenSSH with an outbound stdio channel whose remote exec command is exactly:

```text
cmux machine register
```

The destination, port, and optional identity file are local OpenSSH arguments. The remote command contains no user input and overrides any configured remote command. Agent and port forwarding are disabled. An explicit identity also sets `IdentitiesOnly=yes`.

The long-lived process sets `BatchMode=yes`, so restart cannot block on a password, key passphrase, or host-key prompt. Before starting it, the user must complete an interactive `ssh cmux.cloud` once to trust the host and verify that an SSH agent or unencrypted key can authenticate. The agent does not edit SSH config, shell startup files, or service definitions.

There is one steady-state SSH connection. A broker-requested generation migration temporarily opens a replacement while the old generation drains existing streams.

## Registration protocol v1

Frames are newline-delimited JSON envelopes. Every envelope contains protocol `cmux.machine-agent`, version `1`, and one strict tagged message. Unknown fields, message kinds, protocol names, and versions fail closed. A frame is at most 64 KiB.

The first agent frame is `hello`:

| Field | Meaning |
| --- | --- |
| `machine_id` | Stable random machine identity |
| `secret` | Stable random registration secret |
| `connection_nonce` | Fresh random 128-bit connection nonce |
| `session` | Selected local cmux session |
| `agent_version` | Agent package version |
| `minimum_generation` | Lowest acceptable broker generation |
| `migration` | Optional broker-issued generation and one-use token |

The broker replies with `registered`, including the same machine id, an accepted generation, a heartbeat interval, and an optional one-time pairing code. The interval must be between 100 milliseconds and 60 seconds. The agent prints a pairing code to the controlling terminal and does not persist it.

On first registration, the broker must atomically bind the machine id and secret to the authenticated SSH principal before issuing a pairing code. Later registrations must prove the same secret. The broker must reject a reused connection nonce, a changed secret, an expired migration token, and any generation below `minimum_generation`.

## Stream multiplexing

The broker opens a stream with a nonzero stream id, a generation-independent replay id, and initial agent-to-broker credit. The agent opens a fresh connection to the selected local protocol-v9 socket and replies with `opened` plus broker-to-agent credit.

`data` carries at most 24 KiB as unpadded base64. `window` replenishes byte credit. A zero-length `data`, zero-byte `window`, credit overflow, or data beyond available credit closes that stream with `flow_control`. A local read or write failure closes only its stream. `close` is idempotent.

One generation supports at most 64 active streams. The agent retains 1,024 recent open ids across generations and rejects replay. Per-direction stream credit is capped at 1 MiB. Internal event queues are bounded at 128 entries. Local queue exhaustion closes the affected stream, while cloud input applies transport backpressure.

`ping` and `pong` keep the registration live. No received frame for three heartbeat intervals replaces the connection. Registration has a 10-second handshake deadline. Reconnect delay starts at 250 milliseconds, doubles to 30 seconds, and adds up to 25 percent random jitter. Shutdown interrupts the wait.

## Generation migration

The broker requests a higher generation with `reconnect_generation` and a fresh one-use token. The agent stops accepting new streams on the old generation, but its existing streams remain live. It opens a replacement `hello` carrying the requested generation and token.

The old connection remains healthy until the replacement returns `registered` for the exact requested generation. The agent then sends `generation_ready` on the old connection. The broker routes new streams to the replacement while old streams drain. The old agent sends `drain_complete` only after its final stream closes.

If replacement registration fails, the agent sends `generation_rejected` and resumes the old generation. Lower generations, repeated generations, and reused migration tokens are rejected. The broker must not close the old generation before `generation_ready`.

## Local state

The default identity is stored in `identity.json` inside the private `machine-agent/` directory beside the normal cmux config. `--state` selects another file path. A missing parent state directory is created with mode 0700. Existing directories must be owned by the current user and inaccessible to group and others.

The identity file contains only schema version, machine id, and machine secret. It must be a current-user-owned regular file with mode 0600 and exactly one link. Symlinks and hard links are rejected. A process-lifetime nonblocking lock keyed by machine id and session prevents two agents from flapping one registration.

Secrets, pairing codes, migration tokens, and data payloads redact debug output. Owned serialization and relay buffers are overwritten before release, including error paths.
