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

## Driver contracts baked in

- e2b: template start command runs `cmuxd-remote serve --ws` on 7777 with
  `/tmp/cmux` lease files, readiness-gated on `/healthz`
  (build-devbox-e2b.ts sets it; the driver reads lease paths from `ps`).
- daytona: `/usr/local/bin/cmux-daytona-entrypoint` supervises the same
  serve command and is registered as the snapshot entrypoint, so Daytona
  restarts the daemon on every stop/start cycle.
- freestyle: the driver installs the cmuxd-ws systemd unit at create time
  (or the bake bakes the signed-admin unit when
  `CMUX_FREESTYLE_ADMIN_SIGNING_PUBLIC_KEY` is set), pointing at the baked
  `/usr/local/bin/cmuxd-remote`. Its managed-shell probe requires the cmux
  user, zsh, `/etc/cmux/zshrc`, and `/home/cmux/.zshrc`; all are baked, and
  a miss would make the driver overwrite `cmux-cloud-shell` with its
  fallback zsh shell.
- Every provider's PTY shell is `/usr/local/bin/cmux-cloud-shell`, which
  drops a root daemon to the `cmux` user and starts a login bash (the
  devshell).

## Bake

Run from `web/`. Each script builds `cmuxd-remote` (linux/amd64, from
`daemon/remote`) into the gitignored `.build/` context first, and refuses a
stale checkout (`CMUX_BAKE_ALLOW_BRANCH=1` for deliberate branch bakes).

```bash
E2B_API_KEY=...       bun scripts/build-devbox-e2b.ts --tag <tag>        # skipCache by default
DAYTONA_API_KEY=...   bun scripts/build-devbox-daytona.ts cmux-devbox-<tag>
FREESTYLE_API_KEY=... bun scripts/build-devbox-freestyle.ts cmux-devbox-<tag>
```

Daytona snapshot names are immutable: always a fresh versioned name.
Freestyle needs a daemon download URL: `CMUX_REMOTE_DAEMON_BUILD_URL`, or
`R2_ENDPOINT` + `R2_BUCKET_NAME` + `R2_ACCESS_KEY_ID` + `R2_SECRET_ACCESS_KEY`
for an upload + presign. Agent pins live only in the Dockerfile ARG defaults;
bump them together with `CMUX_IMAGE_EPOCH` and the Blaxel template.

## Verify

Each bake prints a `next` command. The verifier boots one sandbox on the
named provider, asserts the toolchain, the exact agent pins, ghost text
under a tmux PTY, byte-identical baked files, and the provider's daemon
contract, then deletes the sandbox:

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
`defaultForLocalDev` only from a validated entry.
