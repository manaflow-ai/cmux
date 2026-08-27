# cmux Cloud devbox image (e2b / daytona / freestyle)

One devbox definition for the three non-Blaxel Cloud VM providers. The
Dockerfile here is the source of truth for E2B and Daytona;
`web/scripts/build-devbox-freestyle.ts` replays the same steps over
Freestyle exec (its build API has no COPY). Parity targets are the chatmux
devbox (`chatmux:infra/sandbox-images/Dockerfile`) and the Blaxel
`cmux-devbox` template (`../blaxel/`): same devtools, mise node/python/bun,
uv, gh, Chrome + cua-driver, pinned coding agents, ble.sh ghost text,
half-life prompt, seeded history, and the coderouter agent-config generator.
Blaxel keeps its own template; nothing here changes it.

`vm-devbox-image.test.ts` pins the shared files (`cmux-bashrc`,
`agent-config.sh`, `seed-history`, `chrome-managed-policy.json`) to their
Blaxel counterparts, so edit both copies together.

## Session daemon: cmux-tui

Every provider attaches through the cmux-tui remote daemon on port 1337
(transport `cmux-remote`, docs/cloud-cmux-tui-daemon.md) — the same model as
Blaxel. The binary is NOT baked: each driver installs the pinned
files.cmux.com build (sha256-verified) at create time and heals pin drift on
attach (`web/services/vms/drivers/cmuxTuiDaemon.ts`). The image ships only
`cmux-devbox-boot`, the supervisor that waits for the binary and restarts
the daemon:

- e2b: no start command; the driver starts the daemon as a root background
  command (E2B pause/resume preserves processes) and heals on attach. The
  route is the sandbox's public port host (`wss://1337-<id>.e2b.app/v1/link`);
  the E2B proxy's only request auth is a header the cmux-tui dialer cannot
  send, so sandboxes are created with public port traffic and the daemon's
  Noise device enrollment gates sessions.
- daytona: `cmux-devbox-boot` is the registered snapshot entrypoint. Stop
  kills processes while the disk (binary, daemon identity under /root)
  persists; start re-runs the entrypoint. The route is the preview proxy
  with its token as the `DAYTONA_SANDBOX_AUTH_KEY` query parameter, minted
  fresh per attach.
- freestyle (beta platform, `freestyle-beta` npm alias): the baked
  `cmux-tui-daemon` systemd unit runs the supervisor. FORWARD-COMPATIBLE
  ONLY: the shipped freestyle driver still speaks the legacy 0.1.51 platform
  and its cmuxd-remote transport, so this bake becomes usable when a
  beta-SDK freestyle driver lands; until then `FREESTYLE_SANDBOX_SNAPSHOT`
  must not point at it.

Shells spawned by the daemon run as root with HOME=/root and get the bash
devshell (ble.sh ghost text, half-life prompt, seeded history) through the
`/etc/bash.bashrc` chain, exactly like Blaxel machines.

## Bake

Run from `web/`. Each script refuses a stale checkout
(`CMUX_BAKE_ALLOW_BRANCH=1` for deliberate branch bakes). No local Docker
and no daemon build are needed.

```bash
E2B_API_KEY=...       bun scripts/build-devbox-e2b.ts --tag <tag>        # skipCache by default
DAYTONA_API_KEY=...   bun scripts/build-devbox-daytona.ts cmux-devbox-<tag>
FREESTYLE_API_KEY=... bun scripts/build-devbox-freestyle.ts cmux-devbox-<tag>
```

Daytona snapshot names are immutable: always a fresh versioned name.
Freestyle (beta) auth is `FREESTYLE_API_KEY`, or
`FREESTYLE_STACK_ACCESS_TOKEN` + `FREESTYLE_TEAM_ID`; the argument is the
snapshot slug (falls back to slugless on a collision) and the printed
`sh-…` id is the pointer to pin. Agent pins live only in the Dockerfile ARG
defaults; bump them together with `CMUX_IMAGE_EPOCH` and the Blaxel
template. The cmux-tui pin comes from the artifacts manifest at deploy time
(`CMUX_VM_CMUX_TUI_MANIFEST_URL`), never from the image.

## Verify

Each bake prints a `next` command. The verifier boots one sandbox on the
named provider, asserts the toolchain, the exact agent pins, ghost text
under a tmux PTY, and byte-identical baked files, then replays the driver's
create-time cmux-tui bootstrap and asserts the daemon contract (session
answering, port 1337 listening, the provider's supervisor alive), and
deletes the sandbox:

```bash
bun scripts/verify-devbox-image.ts e2b cmux-devbox:<tag>
bun scripts/verify-devbox-image.ts daytona cmux-devbox-<tag>
bun scripts/verify-devbox-image.ts freestyle <sh-snapshot-id>
```

## Manifest

Only after verify passes: take the `manifestEntry` the bake printed, set
`validationStatus` to `passed`, describe the validation in `notes`, and add
it to `web/services/vms/images/manifest.json` (append; never rewrite
existing entries). Point the env var at the new image
(`E2B_CMUXD_WS_TEMPLATE` / `DAYTONA_SANDBOX_SNAPSHOT` /
`FREESTYLE_SANDBOX_SNAPSHOT`) where it should serve, and flip
`defaultForLocalDev` only from a validated entry. Machines created from the
old cmuxd-remote images cannot serve the `cmux-remote` transport and need
recreation on a devbox image.
