# Rift workspaces for agents: evaluation (2026-10-22)

Question (msg 9594): can [Rift](https://github.com/anomalyco/rift) (v0.0.13, APFS `clonefile`
copy-on-write workspaces, OpenCode's worktree backend) make an agent's first green build faster than
today's `git worktree add` + cold install + cold build?

Decision: **do not adopt Rift.** It is 6.2x faster to a first green build, but almost all of that
comes from cloning the warm build caches. A normal `git worktree add` plus `cp -c` (clonefile) of
those caches gets 5.7x and has none of Rift's git hazards (below). The follow-up worth doing is a
small opt-in "seed caches by clonefile" step for agent worktrees, not a Rift dependency.

## How it was measured

`scripts/measure/rift-eval.sh` on feat-cmux-next, run as an exclusive fleet step (alone on the host):
step `78dcd3c1aee9f2029fb87cd6` at `4556ff64740`, on cmuxs-Mac-mini-4 (M4 Pro, 14 cores, macOS 27.0.1,
APFS). It makes a warm seed clone (bun install + `bun run build` of webviews, `cargo build -p acpmux`
of cmux-tui, `swift build --product CmuxNextApp` of CmuxNext), then times three ways to get a second,
ready workspace:

- (a) `git worktree add` + install + first build (what agents do today)
- (b) `rift create --copy-all` from the warm seed, then a build
- (c) `git worktree add` + `cp -c -R` of the seed's `webviews/node_modules`, `cmux-tui/target` and
  `Packages/macOS/CmuxNext/.build`, then install + build

Every lane ends with one source edit and an incremental build. Disk is the drop in free space.

## Numbers (seconds)

| step | (a) git worktree | (b) rift | (c) worktree + clonefile caches |
|---|---|---|---|
| create workspace | 3.6 | 2.8 | 4.4 + 13.1 cache clone |
| webviews: install / first build | 0.8 / 7.3 | – / 8.8 | 0.4 / 7.7 |
| acpmux (Rust): fetch / first build | 0.3 / 88.1 | – / 29.9 | 0.6 / 29.3 |
| CmuxNext (Swift): resolve / first build | 23.7 / 295.4 | – / 25.6 | 13.5 / 5.1 |
| **total to first green build** | **419.2** | **67.1 (6.2x)** | **74.1 (5.7x)** |
| edit + incremental build (bun / rust / swift) | 6.0 / 4.8 / 9.8 | 7.7 / 5.2 / 4.8 | 6.1 / 5.0 / 4.8 |
| disk used | 10,027 MiB | 40 MiB | 1,008 MiB |

The seed's own cold builds were bun 8.0 s, Rust 86.3 s and Swift 275.0 s, so (a) is a full cold build
each time. Rift's other operations: `rift init` 0.3 s, four concurrent creates 5.2 s (4 of 4 OK),
`rift remove` 0.0 s, `rift gc` 5.8 s.

Notes:
- A cloned cache is not a free build. Rust rebuilt about 30 s of workspace crates and Swift about
  5–25 s, because cargo and SwiftPM put absolute paths in their fingerprints and the path changed.
  That is the same for (b) and (c).
- Edit-then-rebuild is the same in all lanes (5–10 s). Rift helps only the first build.

## Git safety of Rift (v0.0.13)

- A rift is a **full copy of the repository**: its own `.git` directory, detached `HEAD`, no
  alternates. A branch or commit made in a rift is not in the source checkout (checked). An agent must
  push from the rift itself. Each copy also runs its own `git gc` and object store.
- **It copies the source's linked-worktree registry.** In the rift, `git worktree list` showed the
  seed's worktree `wt-a` as its own. `git worktree remove` or `prune` there acts on another agent's
  directory. This is a real hazard for us, because every agent works in a linked worktree.
- **It refuses to start from a linked worktree** ("no initialized workspace found"). It also refuses
  during a merge, rebase, cherry-pick or bisect, or while a lock file is present. So the source must
  be a full, idle, warm clone that one process owns, not an agent's worktree.
- The main checkout is a partial (blobless) clone shared by the user and agents. Rift would copy its
  whole `.git` (clonefile makes that cheap) but would also copy its partial-clone state, so every rift
  fetches missing blobs on its own.
- Rift registers in a SQLite file under the user's data directory, and `remove` only moves the
  workspace to `.trash` until someone runs `rift gc`. Without a scheduled `gc`, the disk is not freed.

## Freestyle VMs

Rift does not help the cloud subagents (cloud-subagents-DESIGN.md). Each VM is already a
copy-on-write fork of one base snapshot (8.7 s up, 1.06 GB its own). On Linux, Rift needs btrfs or a
filesystem with working `FICLONE` reflinks, and it has no byte-copy fallback, so it fails on ext4. The
VM equivalent of (c) is to put warm `node_modules`/`target` in the base snapshot, which the fork
already shares copy-on-write. That is a base-image change, not a Rift change.

## Follow-up (not done here)

An opt-in agent worktree helper: `git worktree add`, then `cp -c -R` of `webviews/node_modules`,
`cmux-tui/target` and `Packages/macOS/CmuxNext/.build` from one warm, owner-maintained checkout on the
same APFS volume, falling back to a cold build when the source is missing or on another volume. It
gives 5.7x without a new tool. Swift's absolute-path rebuild and a stale-cache guard (toolchain and
lockfile hashes) need checks before it becomes the default.

## Cleanup

Every workspace, rift and registry the measurement made was in the step's temporary directory, and the
script's exit trap deleted it. Nothing was created on a developer Mac.
