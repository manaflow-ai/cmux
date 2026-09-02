# cmux Cloud devbox image (Freestyle)

The devbox definition for cmux Cloud machines. The Dockerfile here is the
reference recipe (container providers used to build it directly);
`web/scripts/build-devbox-freestyle.ts` builds the same devbox on top of
the `freestyle/ubuntu` base VM and adds the **desktop layer** from
`desktop/`. Parity targets are the chatmux
devbox (`chatmux:infra/sandbox-images/Dockerfile`): same devtools,
node/python/bun, uv, gh, Chrome + cua-driver, pinned coding agents, ble.sh
ghost text, half-life prompt, seeded history, and the coderouter
agent-config generator.

On Freestyle the toolchain is the base's, not mise: `freestyle/ubuntu`
already ships Node LTS under nvm (symlinked into `/usr/local/bin`), Bun,
Python 3.12, uv, Docker (running from boot), and its own copies of Claude
Code, Codex and OpenCode. The bake keeps all of that and replaces the agent
copies with the exact Dockerfile pins (`npm install -g` on the base's npm,
every agent bin symlinked into `/usr/local/bin` so daemon panes resolve them
without a login profile). The work user is the base's **`ubuntu`** (uid
1000, passwordless sudo, the API's default exec user and the SSH default);
the bake creates no users. A cmux login banner (`cmux-motd`, rendered by
pam_motd on SSH) replaces the stock Ubuntu and Freestyle motd text.

`vm-devbox-image.test.ts` pins the shared files (`cmux-bashrc`,
`agent-config.sh`, `seed-history`, `chrome-managed-policy.json`) to their
chatmux counterparts, so edit both copies together.

## Desktop layer (`desktop/`, Freestyle)

Ported from the retired Blaxel `sandbox/cmux-devbox` image: an
openbox/TigerVNC desktop with a tint2 dock (Chrome, Files, Ghostty), a CC0
wallpaper, and noVNC on 6901. The contract the Mac CLI and any provider
heal depend on (`vm-devbox-desktop.test.ts` pins it):

- `start-vnc.sh` runs as the work user `ubuntu` with `HOME=/home/ubuntu`
  and `DISPLAY=:1`, so the desktop session is the same account terminals
  and SSH land in; RFB on **5901 loopback-only** (no VNC auth; the only
  ingress is a token-gated proxy in front of websockify), noVNC via
  websockify on **6901** at `/`.
- The `cmux-desktop` systemd unit runs `cmux-desktop-boot`, which re-asserts
  Chrome's pre-accepted first run and re-runs the idempotent `start-vnc.sh`
  every 30 s.
- `ubuntu` has passwordless sudo, so coding agents' root-refusing modes
  (`claude --dangerously-skip-permissions`) work. The Freestyle driver still
  runs the cmux-tui daemon as root; moving sessions to `ubuntu` is a driver
  change.
- Ghostty comes from a pinned community `.deb` for Ubuntu 24.04
  (`DEVBOX_GHOSTTY_DEB_URL` in `devbox-image-common.ts`).

A desktop image is a superset of a base one, so one Freestyle snapshot is
registered under both kinds (`desktop` and `base`). `--no-desktop` bakes a
shell-only snapshot. Not yet wired: the Freestyle driver still runs the
daemon as root and exposes no ingress to 6901 (a `style.dev` or
`*.vm.cmux.sh` TLS rule is the intended path; see `desktopWrapper.ts`).

## Session daemon: cmux-tui

Machines attach through the cmux-tui remote daemon on port 1337
(transport `cmux-remote`, docs/cloud-cmux-tui-daemon.md). The Freestyle bake
installs the pinned files.cmux.com build (sha256-verified, the driver's own
install command) at `/root/.cmux/bin/cmux-tui`, proves the daemon answers,
then parks it, because a Freestyle snapshot is a memory image and a live
daemon would give every machine the builder's Noise identity. The
`cmux-devbox-boot` supervisor, run by the baked `cmux-tui-daemon` systemd
unit with `CMUX_TUI_REMOTE_WS_BIND=[::]:1337` (the driver reaches the daemon
at the VM's IPv6 address, so the listener must be dual-stack), reads the
platform instance id from the metadata service, wipes the remote identity
when the machine is a clone, and starts the daemon. The driver runs no
bootstrap at create; it heals pin drift and a missing listener on attach
(`web/services/vms/drivers/cmuxTuiDaemon.ts`). The container Dockerfile still
ships only the supervisor and waits for a driver install.

Shells spawned by the daemon get the bash devshell (ble.sh ghost text,
half-life prompt, seeded history) through the `/etc/bash.bashrc` chain.

## Sizes: one bake, one snapshot per size

A Freestyle VM boots at its snapshot's size and resize is grow-only, so the
bake happens once on the ladder floor (`freestyle/ubuntu-sm`, 2 vCPU / 4 GiB /
16 GB) and `derive-devbox-sizes.ts` turns it into one snapshot per size:
boot the bake, `vm.resize`, snapshot, delete, then boot the derived snapshot
once more and check `nproc`, memory, the grown root filesystem and the
daemon/desktop units. Sizes are Freestyle's own ladder
(`web/services/vms/images/sizes.ts`, verbatim from freestyle-vms
`catalog/snapshots.json`), so every cmux machine is a shape Freestyle already
bills and caps:

| name | vCPU | memory | disk | Freestyle base |
|---|---|---|---|---|
| `sm` | 2 | 4 GiB | 16 GB | `freestyle/ubuntu-sm` |
| `md` | 4 | 8 GiB | 32 GB | `freestyle/ubuntu` |
| `lg` | 8 | 16 GiB | 64 GB | `freestyle/ubuntu-lg` |
| `xl` | 16 | 32 GiB | 128 GB | `freestyle/ubuntu-xl` |
| `2xl` | 32 | 64 GiB | 128 GB | `freestyle/ubuntu-2xl` |

The manifest records one entry per kind and size (`size: { name, cpu,
memoryMb, storageMb }`), each the default for its kind+size. The resolver
picks the smallest size whose memory covers the plan's `memoryMb`
(`defaultMemoryMbForPlan`; today's paid default of 24 GiB lands on `xl`), so
the driver never resizes at create and nothing has to grow at boot. Snapshot
slugs are `cmux-devbox-<size>` (`cmux-devbox` for `md`).

## Promote: bake, verify, derive sizes, record (one command)

The checked-in manifest (`web/services/vms/images/manifest.json`) is the
only source of truth for the image users get: the resolver serves the entry
flagged `defaultForKind` for the requested kind and the plan's size, in local
dev and every deployed runtime alike, and no env var selects or overrides
it. `promote-devbox-image.ts` is the only sanctioned writer:

```bash
# from web/, with the Freestyle key in env
FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle                     # bake -> verify -> sm,md,lg,xl,2xl -> manifest
FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --sizes lg,xl       # a subset of the ladder
FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --sizes none        # one size-less entry (pre-ladder behaviour)
FREESTYLE_API_KEY=... bun run devbox:promote -- freestyle --image sh-…        # verify + derive + record an existing bake
```

Snapshots are account-scoped: promote under the Freestyle account the
deployment's `FREESTYLE_API_KEY` belongs to, or the recorded ids are
unreachable from production.

It runs the stale-checkout preflight (`CMUX_BAKE_ALLOW_BRANCH=1` for
deliberate branch bakes), the bake, then `verify-devbox-image.ts`; only a
passing verify derives the sizes and writes the manifest, appending one
entry per kind and size flagged `defaultForKind` while demoting the
provider's previous defaults for those kind+size pairs (a sized promotion
also demotes size-less defaults: the ladder replaces the single-shape
image). Existing entries are never removed, so rollback is a manifest
revert. The last stdout line is `IMAGE_ID <id>` (the bake); `--out <json>`
writes the summary with every derived id. Commit the manifest diff in a PR;
merging it is the promotion.

## Bake and verify by hand

Each script refuses a stale checkout (`CMUX_BAKE_ALLOW_BRANCH=1` for
deliberate branch bakes). No local Docker and no daemon build are needed.

```bash
FREESTYLE_API_KEY=... bun scripts/build-devbox-freestyle.ts cmux-devbox-<tag> [--no-desktop] [--replace-slug]
```

Freestyle bakes on `freestyle/ubuntu` (4 vCPU / 8 GiB / 32 GB): VMs always
boot at their snapshot's size and resizing is grow-only, so the builder's
shape is what every cmux Cloud machine gets. Freestyle snapshot slugs are
reassignable; the printed `sh-…` id is the pointer to pin. Agent pins live
only in the Dockerfile ARG defaults; bump them together with
`CMUX_IMAGE_EPOCH` and the chatmux template. The cmux-tui pin comes from
the artifacts manifest at deploy time (`CMUX_VM_CMUX_TUI_MANIFEST_URL`),
never from the image.

Each bake prints a `next` command. The verifier boots one VM from the
snapshot, asserts the toolchain, the exact agent pins, ghost text
under a tmux PTY, byte-identical baked files, the work user, and (when
`/etc/cmux/image-stamp` says `desktop`) the desktop contract, then waits for
the baked daemon to come up on its own, asserts the daemon contract (current
pin, identity bound to this instance id) and that a second machine from the
snapshot holds a different daemon identity, and deletes both sandboxes:

```bash
bun scripts/verify-devbox-image.ts freestyle <sh-snapshot-id>
```

Only after verify passes may an entry carry `validationStatus: "passed"`;
`vm-image-manifest.test.ts` refuses a `defaultForKind` entry with any other
status. Machines created from the old cmuxd-remote images cannot serve the
`cmux-remote` transport and need recreation on a devbox image.
