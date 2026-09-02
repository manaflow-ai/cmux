# cmux Cloud devbox image (freestyle)

The devbox definition for cmux Cloud VMs. The Dockerfile here is the source of
truth; `web/scripts/build-devbox-freestyle.ts` replays the same steps over
Freestyle exec (its build API has no COPY). Parity targets are the chatmux
devbox (`chatmux:infra/sandbox-images/Dockerfile`): same devtools, mise node/python/bun,
uv, gh, Chrome + cua-driver, pinned coding agents, ble.sh ghost text,
half-life prompt, seeded history, and the coderouter agent-config generator.

`vm-devbox-image.test.ts` pins the shared files (`cmux-bashrc`,
`agent-config.sh`, `seed-history`, `chrome-managed-policy.json`) to their
chatmux counterparts, so edit both copies together.

## Session daemon: cmux-tui

Machines attach through the cmux-tui remote daemon on port 1337 (transport
`cmux-remote`, docs/cloud-cmux-tui-daemon.md). The binary is NOT baked: the
driver installs the pinned files.cmux.com build (sha256-verified) at create
time and heals pin drift on attach
(`web/services/vms/drivers/cmuxTuiDaemon.ts`). The image ships only
`cmux-devbox-boot`, the supervisor that waits for the binary and restarts the
daemon.

The baked `cmux-tui-daemon` systemd unit runs that supervisor with
`CMUX_TUI_REMOTE_WS_BIND=[::]:1337`. The platform has no HTTP ingress to
arbitrary ports, so the route is the VM's stable public IPv6 straight to the
daemon (`ws://[ipv6]:1337/v1/link`, Noise enrollment as the session gate) and
the listener must therefore be dual-stack.

Shells spawned by the daemon run as root with HOME=/root and get the bash
devshell (ble.sh ghost text, half-life prompt, seeded history) through the
`/etc/bash.bashrc` chain.

## Bake

Run from `web/`. The script refuses a stale checkout
(`CMUX_BAKE_ALLOW_BRANCH=1` for deliberate branch bakes). No local Docker
and no daemon build are needed.

```bash
FREESTYLE_API_KEY=... bun scripts/build-devbox-freestyle.ts cmux-devbox-<tag>
```

Auth is `FREESTYLE_API_KEY`, or `FREESTYLE_STACK_ACCESS_TOKEN` +
`FREESTYLE_TEAM_ID`; the argument is the snapshot slug (falls back to slugless
on a collision) and the printed `sh-…` id is the pointer to pin. Agent pins
live only in the Dockerfile ARG defaults; bump them together with
`CMUX_IMAGE_EPOCH` and the chatmux template. The cmux-tui pin comes from the
artifacts manifest at deploy time (`CMUX_VM_CMUX_TUI_MANIFEST_URL`), never
from the image.

## Verify

The bake prints a `next` command. The verifier boots one machine, asserts the
toolchain, the exact agent pins, ghost text under a tmux PTY, and
byte-identical baked files, then replays the driver's create-time cmux-tui
bootstrap and asserts the daemon contract (session answering, port 1337
listening, the systemd supervisor alive), and deletes the machine:

```bash
bun scripts/verify-devbox-image.ts freestyle <sh-snapshot-id>
```

## Manifest

Only after verify passes: take the `manifestEntry` the bake printed, set
`validationStatus` to `passed`, describe the validation in `notes`, and add
it to `web/services/vms/images/manifest.json` (append; never rewrite
existing entries). Point `FREESTYLE_SANDBOX_SNAPSHOT` at the new image where
it should serve, and flip `defaultForLocalDev` only from a validated entry.
Machines created from the old cmuxd-remote images cannot serve the
`cmux-remote` transport and need recreation on a devbox image.
