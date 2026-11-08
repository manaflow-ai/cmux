# Project environments in the cloud: `cmux vm dev`

Status: design. The command examples below use the shipped grammar; manifest
replay and automatic machine selection remain proposed. Builds on the shipped primitives (route/push/exec/workspace/terminal,
per-size snapshots, VPC + tunnel, in-VM `cmux`); nothing here invents a new transport.

## The user's mental model

Users don't think in machines; they think in *projects*. The unit of "send stuff to
the cloud" is the directory they're standing in, and the promise is: **one verb turns
this directory into a running cloud environment with a workspace named after it** —
terminals, deps installed, checks green — and the same verb later is a fast no-op.

```bash
cmux vm dev <machine>                       # prepare this directory on the selected machine
cmux vm dev <machine> --command "bun test"   # use bun test as the workspace command
```

## What the verb does (all existing primitives)

1. **Route** — the sticky per-directory binding (`vm route`) picks the machine;
   provision on first use, reuse (warm deps) after.
2. **Sync** — push the working tree to `work/<name>` (`vm push` chunking; default
   excludes; `--watch` re-pushes on local change, mtime/size scan). Files that are
   themselves secrets (deploy keys, kubeconfigs, `.npmrc` with a token) never
   ride the exec channel: `vm push --secret <m> <file> <remote-path> [--mode]`
   goes over the machine's link into `cmux file receive`, the same echo-off
   receiver protocol as `vm env set`, and lands 0600 by an atomic rename.
3. **Set up the environment** — the new part, below.
4. **Name the workspace** — create/reuse a cmux-tui workspace on the machine named
   after the project (`vm workspace new`), so the sidebar and `vm tree` show
   *myrepo* with its terminals, not an anonymous `main`. New terminals for this
   project land there (`--remote-workspace`).
   With a `layout` in the manifest, the workspace is built by `vm layout apply`
   (shipped) and opens on the Mac with the same geometry.
5. **Verify** — run the manifest's `checks` (e.g. `bun test --help`) in a durable
   terminal; print the workspace address; open it unless `--detach`.

## Environment setup: detect, record, replay

Setup must be automatic on first contact and deterministic after.

- **Detect** (first run, no config): look at the synced tree — `devcontainer.json`
  (honored first-class: image/features/postCreate), lockfiles (`bun.lock`,
  `pnpm-lock.yaml`, `package-lock.json`, `uv.lock`, `poetry.lock`,
  `requirements.txt`, `Cargo.toml`, `go.mod`), toolchain files (`.tool-versions`,
  `mise.toml`, `.nvmrc`, `rust-toolchain.toml`). The devbox image already carries
  mise/node/bun/uv/cargo-adjacent tooling, so most detections are one install
  command, not a provisioning script.
- **Record** — write the resolved recipe to `.cmux/cloud.json` in the repo
  (committable, reviewable):

  ```json
  {
    "name": "myrepo",
    "size": "20g",
    "setup": ["bun install"],
    "checks": ["bun run typecheck"],
    "env": ["DATABASE_URL"],
    "ports": [3000]
  }
  ```

- **Replay** — later `vm dev` runs sync + the recipe's delta only (lockfile hash
  gates the install). A repo that ships `.cmux/cloud.json` never runs detection:
  what the file says is what happens, on every machine, for every teammate.
- **Secrets** (`env`) are *named*, never valued, in the repo. Values come from
  `cmux vm env set <machine> DATABASE_URL=…` — shipped today as a machine-local
  file (`~/.config/cmux/env` in the work user's home, 0600, on the persistent volume, sourced by every
  shell cmux starts). Control-plane storage per (user, project) with materialization
  at setup and revocation with access is the next step, and the long game is values
  living at the TLS edge (docs/vm-identity-edge-auth.md), not in the guest at all.
- **Layout** (`layout`) is the workspace shape the manifest can carry — the same
  `CmuxLayoutNode` document `cmux vm layout apply` takes today — so `vm dev` can end
  in a finished workspace (agent pane, test watcher, dev server + browser) instead
  of one shell.
- **Ports** pre-registers the project's dev-server ports so `vm tree` shows them
  (and `vm open <m>:port/<n>` works) before the first probe.

## Why this shape

- **One verb, idempotent** — "set up" and "reconnect" are the same action, so users
  never learn two flows. Slow paths (provision, first install) happen at most once
  per (project, machine); the router's stickiness is what makes the second run
  instant.
- **The repo is the source of truth** — `.cmux/cloud.json` (or devcontainer.json)
  makes environments reproducible across machines, forks (`vm fork` for a parallel
  experiment inherits a working env), and teammates, and makes "it works in my
  cloud" reviewable in a PR.
- **Workspaces mirror projects** — naming the machine workspace after the project
  is what makes the sidebar legible when one machine hosts several checkouts, and
  gives `vm dev -- <cmd>`, `vm agent --sync`, and the in-VM `cmux` a stable home.

## Phasing

1. **P1** — `cmux vm dev`: route + sync + lockfile detection (bun/pnpm/npm/uv/pip/
   cargo/go) + named workspace + `--` command passthrough. No manifest yet;
   detection prints what it ran and suggests committing the generated
   `.cmux/cloud.json`.
2. **P2** — manifest replay with lockfile-hash gating, `checks`, `ports`,
   `layout`, `vm dev --watch` incremental sync (`vm env set/ls/rm` already exists
   machine-local; P2 reads the manifest's `env` names and reports which are unset).
3. **P3** — devcontainer.json compatibility, per-project size, fork-aware setup
   (a fork skips setup when the lockfile hash matches), edge-resident secrets.
