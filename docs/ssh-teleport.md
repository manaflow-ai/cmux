# Teleport (`tsh`) SSH support

cmux can open an SSH workspace through Teleport's client by selecting the
`tsh` transport. It is **interactive-only**: the workspace terminal runs
`tsh ssh <destination>` directly, with no cmux remote daemon.

## Entrypoints

| Surface | How |
| --- | --- |
| CLI | `cmux ssh --via tsh user@node` (default `--via ssh`) |
| Deep link (cmux scheme) | `cmux://ssh?host=node&user=admin&via=tsh` |
| Deep link (standard) | `ssh://admin@node?via=tsh` |
| Web fallback | `https://cmux.com/deeplink/ssh?host=node&user=admin&via=tsh` |

All of these funnel through one place: `CmuxSSHURLRequest.cliArguments`
emits `--via tsh`, and the bundled CLI's `runInteractiveTeleportSSH`
(`CLI/cmux.swift`) builds the `tsh ssh` command. There is no separate
mutation path per surface.

The accepted `via` values are `ssh`/`openssh` (default) and `tsh`/`teleport`.

## Why interactive-only

The OpenSSH path (`--via ssh`) is a relay pipeline: it bootstraps
`cmuxd-remote` on the host, forwards a control socket, and multiplexes a
reverse relay over an OpenSSH `ControlMaster`. Teleport's `tsh ssh`
**does not honor** the OpenSSH options that pipeline depends on:

- `-o RemoteCommand=…` — used to install/launch `cmuxd-remote`.
- `-o ControlMaster` / `ControlPath` / `-O forward|cancel` — the reverse-relay
  multiplexing mechanism.
- `-o SetEnv` / `SendEnv`, `-o LocalCommand` / `PermitLocalCommand`, `-i`.

So `--via tsh` deliberately emits a **minimal** command: the binary, `-p`
(port), `-A` (agent forwarding when requested), any caller-supplied `-o`
passthroughs, the destination, and any remote command after `--`. It opens a
workspace whose terminal simply `exec`s that command. No relay, no
`workspace.remote.configure`, no daemon auto-connect.

Consequences for `--via tsh` workspaces today:

- No port-forward detection, browser egress proxy, or remote `cmux` agents.
- No reconnect-on-disconnect (the sidebar Reconnect row only appears for
  remote-configured workspaces).
- Remote terminfo is not shipped (that needs `RemoteCommand`), so a host
  lacking `xterm-ghostty` falls back to normal `TERM` negotiation — same as a
  bare `tsh ssh`.

## Investigation: a future relay path via `tsh ssh -R`

Goal: bring the cmux daemon features (port detection, browser egress,
persistent sessions) to Teleport hosts. This is a larger lift than the
interactive path; notes below.

### What the OpenSSH relay does today (the parts to replace)

- **Daemon transport** — runs `cmuxd-remote serve --stdio` on the host and
  pipes its stdio. `WorkspaceRemoteSSHBatchCommandBuilder.daemonTransportArguments`
  already passes the daemon command **positionally** (`sh -c '…'`), not via
  `-o RemoteCommand`. **Positional commands work with `tsh ssh`.**
- **Socket forward** — `daemonSocketForwardArguments` uses `-N -T -S none -L …`.
  `-L` local forwarding is supported by `tsh`; `-S none` and the `-o` defaults
  are OpenSSH-isms tsh ignores/rejects.
- **Reverse relay** — `reverseRelayControlMasterArguments` adds a `-R` forward
  to a live `ControlMaster` via `-O forward`, cancelled with `-O cancel`. There
  is a non-multiplexed fallback `reverseRelayArguments` that runs a standalone
  `ssh -N -T -R 127.0.0.1:<relayPort>:127.0.0.1:<localRelayPort> <dest>`
  (`Sources/Workspace.swift`).

### The open question (verify empirically first)

Does the target Teleport cluster + `tsh` version support **remote** (`-R`)
port forwarding? `tsh ssh` has supported `-L`/`-D` for a long time; `-R`
support is newer and may be gated by cluster config. Verify on the actual
deployment before building anything:

```bash
tsh ssh --help | grep -E '\-L|\-R|\-N|forward'
# then a smoke test:
tsh ssh -N -R 127.0.0.1:0:127.0.0.1:22 user@node   # does it bind a remote listener?
```

If `-R` is unsupported, the relay cannot egress from the host the same way and
this path is blocked until Teleport adds it (or an alternative such as
`tsh proxy ssh` + a side channel is used).

### Design sketch (if `-R` is supported)

1. **Thread the transport into the daemon side.** Add `case teleport` to
   `WorkspaceRemoteTransport` (`Sources/WorkspaceRemoteConfiguration.swift`) and
   plumb it through `workspace.remote.configure`. The CLI would then call
   `configure` for tsh (it currently skips it).
2. **tsh-specific batch arg builders.** Fork the
   `WorkspaceRemoteSSHBatchCommandBuilder` helpers and `sshCommonArguments`
   (`Sources/Workspace.swift`) to emit a tsh-safe vector: drop all `-o`
   defaults (`ConnectTimeout`, `ServerAlive*`, `StrictHostKeyChecking`,
   `BatchMode`, `ControlMaster`), drop `-S`/`-i`, keep `-p`, `-N`, `-T`, `-L`,
   `-R`, and the positional command.
3. **Replace ControlMaster reverse-relay with a dedicated process.** Since tsh
   has no control socket, use the existing standalone-process model
   (`reverseRelayArguments`) but built for tsh, and manage its lifecycle by
   tracking/killing the `Process` instead of `-O cancel`.
4. **Bootstrap `cmuxd-remote` positionally.** The daemon transport already
   uses a positional `sh -c` command, so the bootstrap that installs/launches
   `cmuxd-remote` can run the same way through `tsh ssh <dest> sh -c '…'`.
   `cmuxd-remote` must be reachable/installable on the Teleport node.
5. **Auth/preflight.** Add a `tsh status` preflight so a missing Teleport login
   surfaces as "run `tsh login`" instead of an opaque failure.

### Risk / scope

- Two parallel relay arg-builders (OpenSSH + tsh) increases surface; keep them
  behind the single transport switch and cover both with the batch-builder
  tests.
- No connection multiplexing means each forward is its own `tsh` process —
  more processes to supervise and clean up than the OpenSSH ControlMaster model.
- Behavior is `tsh`/cluster-version dependent; gate on the empirical `-R` check
  above and fail loudly when unsupported.
