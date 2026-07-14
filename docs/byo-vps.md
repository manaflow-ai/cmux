# BYO VPS: direct backends with `cmux vps`

Tracking issue: https://github.com/manaflow-ai/cmux/issues/8003 (this page covers Phase 2, one-command onboarding)

`cmux vps add user@host` turns a bare Linux VPS you already have SSH access to into a first-class cmux backend with a **fully direct data path**: terminal keystrokes, agent transcripts, and browser-pane traffic flow between your Mac and your host only. No manaflow server is in the data path.

```
cmux vps add dev@203.0.113.7          # provision (idempotent; re-run to repair/upgrade)
cmux ssh dev@203.0.113.7              # open a workspace backed by the supervised daemon
cmux vps status                       # health, version drift, live session count
cmux vps upgrade dev@203.0.113.7      # safe daemon upgrade
cmux vps remove dev@203.0.113.7       # teardown (--keep-sessions preserves running PTYs)
```

## What `cmux vps add` does

1. **Probes the host** over your existing SSH auth (ssh config, agent, `-i` identity — cmux never stores or transmits private keys). One read-only shell round trip detects OS/arch (`uname`), distro (`/etc/os-release`), systemd availability, and any existing install.
2. **Installs the daemon binary.** The matching `cmuxd-remote` release build is resolved through the manifest embedded in the app (exact asset URL + pinned SHA-256), downloaded into the shared local cache, verified, uploaded with scp, and **verified again on the host** (`sha256sum` against the pinned digest) before it is atomically moved into place. The install path is the exact path the regular `cmux ssh` bootstrap probes (`~/.cmux/bin/cmuxd-remote/<version>/<os>-<arch>/cmuxd-remote`), so SSH workspaces never re-upload.
3. **Supervises it with systemd.** A unit (`cmux-vps.service`) runs `cmuxd-remote serve --persistent-server --slot vps --idle-timeout 0`:
   - non-root user → user unit under `~/.config/systemd/user`, plus `loginctl enable-linger` so the daemon survives logout. Polkit refuses self-linger for remote sessions on many distros, so provisioning escalates to passwordless `sudo` when available and then **verifies** the linger flag. If it still cannot be enabled, `add` warns and `status` reports **degraded** — the daemon (and its PTY sessions) would stop when your last SSH connection closes — until you run `sudo loginctl enable-linger <user>` on the host once and re-run `cmux vps add`;
   - root → system unit under `/etc/systemd/system`;
   - no systemd → report-only: the binary is installed and everything works via the lazy per-connection daemon, but there is no auto-start on reboot (a warning says exactly that).
   The unit executes a stable `~/.cmux/vps/current` symlink, so upgrades retarget the symlink instead of rewriting the unit.
4. **Verifies health end to end**: a real `hello` through the same stdio → per-user Unix socket → authenticated daemon path workspaces use, then a non-spawning `daemon-status` query for the daemon's own version, uptime, and PTY session count.
5. **Registers the host** in `~/.local/state/cmux/vps/hosts.json` on your Mac. `cmux ssh` consults this registry and pins workspaces on registered hosts to the shared supervised slot, so their PTY sessions live in the systemd-managed daemon and survive disconnects, Mac reboots, and app restarts.

Re-running `add` is idempotent: it converges the host (repairing a corrupt binary by checksum, rewriting a drifted unit, restarting a stopped daemon) and does nothing when everything already matches.

## Security model

- **No new listening ports.** The daemon binds a per-user Unix socket (`/tmp/cmuxd-remote-<uid>/…`) guarded by a `0600` token file; every byte rides your SSH transport. `cmux vps add` opens nothing to the network.
- **Your SSH auth, unchanged.** Provisioning shells out to OpenSSH with `BatchMode=yes`; ssh config, agents (including 1Password/Secretive), and identity files resolve exactly as in a terminal.
- **Checksums everywhere.** Binaries are verified against the release manifest's pinned SHA-256 locally after download *and* on the host after upload. `cmux remote-daemon-status` prints the expected digests and a `gh attestation verify` command.

## Upgrades and live sessions

`cmux vps status` compares the daemon's self-reported version (from its handshake) with the version your cmux installs and shows `needs-upgrade` on drift. `cmux vps upgrade` installs the new binary, retargets the symlink, and restarts the unit.

Restarting the daemon terminates the PTY sessions it hosts. Until daemon-restart reattach lands (#7978), upgrades are conservative: **if the supervised daemon reports live PTY sessions, `upgrade`/`add` refuse and tell you to pass `--force`.** The same guard protects `cmux vps remove`; use `--keep-sessions` to remove supervision while leaving the daemon (and your sessions) running.

## What touches manaflow servers, exactly

| Traffic | Direct VPS workspace (`mode: direct`) | Managed Cloud VM (`mode: cloud_proxied`) |
| --- | --- | --- |
| Terminal I/O (PTY bytes) | Mac ↔ host over SSH only | via cloud WebSocket proxy |
| Agent transcripts / hooks | Mac ↔ host over SSH only | via cloud proxy |
| Browser pane traffic | SOCKS5/CONNECT tunneled over the SSH daemon stream | via cloud proxy |
| Daemon binary download | GitHub Releases (checksum-pinned), from your Mac | pre-baked in VM image |
| Account/auth, updates, optional telemetry | cmux app services as usual (not in the data path) | same |

A direct workspace keeps working if cmux.com is unreachable. The mode is introspectable: `cmux rpc workspace.remote.status` reports `"mode": "direct"` plus a `daemon_health` object (state `running` / `degraded` / `needs-upgrade` / `unreachable`, daemon and client versions, live PTY session count, heartbeat age), and the sidebar tooltip for a connected SSH workspace says "Direct (no cloud proxy)".

## Supported matrix (v1)

- Linux `amd64` / `arm64` with systemd (Debian, Ubuntu, Fedora, etc.): full support including boot auto-start.
- Linux without systemd, FreeBSD: binary install + on-demand daemon, report-only for supervision.
- Anything else: fails with an actionable message before touching the host.

## Host-side debugging

```
~/.cmux/bin/cmuxd-remote/<version>/<os>-<arch>/cmuxd-remote daemon-status --slot vps --json
systemctl --user status cmux-vps.service        # (or plain systemctl for root installs)
journalctl --user -u cmux-vps.service           # daemon logs under systemd
```

`daemon-status` never spawns a daemon; it enumerates every installed version's slot state, dials each socket, and reports version, uptime, and session counts — the same signals `cmux vps status` renders.
