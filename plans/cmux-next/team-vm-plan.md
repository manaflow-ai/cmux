# cmux-next team VM plan (P15)

Status: draft 3, 2026-10-03 (team VM lead). Spike phase A rejected JuiceFS (team-vm-spike.md). The D36 path is accepted (spec C-BATCH 1d30c80): files on local disk, a synchronous journal for acknowledged writes. Journal store measured and chosen (section 4a).

Related plans that this one depends on and does not repeat: vm-image.md (lane 1: image, roles, bind, guest capabilities), server.md (lane 10: VM software, roles, app server lease, Postgres), transport.md (lane 12: overlay, `cmux link`, SSH certificate fetch), tasks.md (Tasks lead: op log store, `Owner::resolve`).

## 1. Facts that change the spec's starting point

1. FUSE works in Freestyle guests. Lane 1 measured it (vm-image.md 6.5): `/dev/fuse` is 0666 once the image installs `fuse3`; POSIX ACLs work on the ext4 root once `acl` is installed; inotify watches survive pause and resume. So the D36 fallback is a contingency, not the expected path. The spike still measures latency, ACLs through the JuiceFS mount, and durability.
2. Tasks storage is an op log, not SQLite (tasks.md section 4, T1). A log is sequential appends with one group-commit fsync per batch, which suits JuiceFS far better than SQLite page writes. The spike measures group-commit latency on the mount with the real `cmux-tasks` store.
3. App Postgres on the team VM stays on local disk (vm-image.md section 5, server.md section 8). So app databases on the team VM are not on the zero-loss tier. Only the files on `/srv/team` (memory, mailbox, projects, app source, app data directories such as the Tasks op log) are zero-loss. This plan does not change that; see section 7, open item O3.
4. The `cmux-next` production branch on PlanetScale is a single node (`PS_5_AWS_ARM`, 0 replicas, read 2026-10-03). A single node does not give the synchronous replication that "zero loss" needs for metadata. `cmux-teamfs` production must be the highly available size (section 6).
5. TeamDO already has an audit chain with `audit_events` in PlanetScale (migration 0005, enterprise lead). Team VM audit indexes into that chain instead of a second index.

## 2. Ownership

| Entity | Owner (single writer) | Others |
| --- | --- | --- |
| team node tree, roles, principal to Linux user mapping, UID and GID allocation (never reused) | `TeamDO` | reconciler on the VM is a projection |
| SSH CA private key, issued-certificate log, revocation list (KRL) | `TeamDO` | `TeamVmDO` pushes the KRL to the VM; sshd reads it |
| VM record (Freestyle VM id, epoch, state, region, snapshot ids), wake leases, routing, gate on/off projection | `TeamVmDO` (new, one per team) | clients, Worker routes |
| gate policy (`team_vm.gate.enabled`, default off) | `TeamDO` TeamPolicy | `TeamVmDO` and the gate read it |
| Linux users, groups, directories, ACLs on the VM | the reconciler (team-host role of `cmux` on the VM) | nobody edits them by hand; drift is reverted and reported |
| team journal (streams `tasks`, `mail`, `memory`, `files`; epoch; high water; R2 segments under `teams/<team>/journal/`) | `TeamVmDO` | the team-host role appends; restore replays |
| files on `/srv/team` (local ext4) | the Linux users that write them, under the permission model | the journal service ships changes; snapshots are the second line |
| team app servers and their data (Tasks first) | the app (server.md lease) | `TeamVmDO` routes ops to it |
| mailbox files, memory repos | the files on the zero-loss tier; writers are Linux users under the permission model | journal service commits history |
| audit records | the audit shipper on the VM appends; the chain head lives in `TeamDO` | dashboard, CLI read |

## 3. Slice order

Each slice lands directly on feat-cmux-next after exact-head gates (lane rules). Slices that touch security, the SSH CA, storage or a schema get a review subagent before landing. Slices under `cmux-tui/` wait for a landing window.

| # | Slice | Where | Depends on | Done when |
| --- | --- | --- | --- | --- |
| S0 | this plan | plans/ | | committed, sent to main |
| S1 | zero-loss storage spike, phase A (section 4) | `cmuxnp-dev-` Freestyle VMs, a `cmuxnp-dev-` R2 bucket, Postgres on a second `cmuxnp-dev-` VM | none | results file with numbers; go or no-go for JuiceFS |
| S1b | journal store measurement (done 2026-10-03, section 4a): a DO behind the API Worker answers in 17 ms p50 from Freestyle; chosen | `cmuxnp-dev-` VM, staging API read only | | numbers in section 4a |
| S2 | `TeamVmDO` (DO migration tag v13): VM record, `team_vm.status`, `team_vm.ensure_awake {lease}`, idempotent provision on team create, epoch fencing, Freestyle driver behind an interface with a fake for tests | backend/apps/api | DO migration tag (v11 requested from the backend lead) | workerd tests: create is idempotent, leases expire, wake on lease, a second provision returns the same VM |
| S3 | SSH CA in `TeamDO`: CA key sealed under a Worker KEK, `team_vm.ssh_cert {pubkey}` (Ed25519 signing in workerd), key id `<principal>/<grant>/<install>/<nonce>`, 15 to 60 min validity, class extensions (D28 force-command for ordinary agents), KRL on revoke | backend/apps/api | S2 | workerd tests; `ssh-keygen -L` parses the certificate; revoked serials appear in the KRL; review subagent clean |
| S4 | reconciler: users, groups `n-<node>-{r,w,a}`, membership closure, node directories, access and default ACLs, setgid, umask 007, mailbox modes, idempotent, drift revert | cmux-tui (team-host role) | S2 for directory events; landing window | Linux container tests on a Testbox (root, real `setfacl`): fixture trees from the spec example table give exactly the spec's access matrix; second run is a no-op |
| S5 | sshd and PAM config for the team role: `TrustedUserCAKeys`, `AuthorizedPrincipalsCommand cmux team principals %u`, `RevokedKeys`, `pam_umask`, force-command, audit login uid | image files (lane 1 owns the image; this lane provides the role's files) | S3, S4 | a `cmuxnp-dev-` VM accepts a fresh certificate, refuses an expired or revoked one, and an ordinary-agent certificate gets only `cmux team …` |
| S6 | team journal: `TeamVmDO` keeps one journal per stream (`tasks`, `mail`, `memory`, `files`) in DO SQLite; `journal.append {stream, epoch, seq, bytes}` is create-if-absent keyed by (stream, seq), refuses a lower epoch after a higher one, returns after the DO storage write is durable; `journal.high_water`, `journal.read {from_seq}`; the DO compacts old entries into R2 segments under `teams/<team>/journal/` through its own binding (no R2 credential on the VM). VM side: the `cmux` team-host role holds the journal client, and `/srv/team` is local ext4 | backend + cmux-tui (team-host role) | S2 | workerd tests: duplicate seq returns the stored ack, stale epoch refused, compaction keeps every acknowledged seq; review subagent clean |
| S7 | Tasks hosting: `cmux-tasks serve` as `app-tasks` on local disk; its `Replica` (cmux-tasks `store/durability.rs`, Tasks lead) calls `journal.append` on stream `tasks` per group commit; Worker to `TeamVmDO` to VM route over the host link; `Owner::TeamVm` resolves; `CMUX_APP_HOST` = per-instance id | backend + cmux-tui (with the Tasks lead) | S2, S6, lane 12 host link, lane 10 app lease | a paused VM serves a Tasks write within the wake budget; kill after acknowledge loses no op (restore replays the journal) |
| S8 | Path A: `cmux team ssh` (ProxyCommand through `cmux link`, certificate fetch and renewal) | cmux-tui cli module (CLI request file) | S3, S5, lane 12 link | `ssh lawrence@acme.team.cmux` works from a Mac with no static key |
| S9 | memory repos and the journal service: `team.memory.write` journals the file content before it returns (zero-loss); plain-tool edits are shipped by an inotify watcher (debounced, stream `files`, recovery point of seconds) and committed to git per principal per burst, author from the audit session | cmux-tui (team-host role) + catalog | S4, S6, S10 session map | `git log` attributes each write to the exact agent principal; a restore keeps every journaled write |
| S10 | audit: auditd watch rules, session id to certificate key id map, hash-chained records shipped to an R2 bucket with a lock rule, indexed into TeamDO's audit chain; `cmux team audit log` | cmux-tui + backend | S5 | a gap in the chain raises an alert; records survive a VM root wipe |
| S11 | mailbox move: `cmux team mail send|watch|ack|list`; `send` journals the message (stream `mail`) before it writes the inbox file and returns; inotify watcher with the `NEW <path> :: <subject>` format; copy from `cmux-lawrence:~/agent-mailbox`; cutover (D32: only after S3 to S8 work) | cmux-tui cli module + a one-time migration script | S3 to S8 | every agent in the directory reads and sends through the team VM; the old mailbox is read-only |
| S12 | Fly.io SSH gate (D33 Path B, D34 off by default): `russh` server with no shell, exec or forwarding, `direct-tcpip` only to teams in the certificate's `cmux-teams` extension, rate limits, admin toggle `team_vm.gate.set` | new crate under cmux-tui or a small standalone service; Fly app | S3, S5; Lawrence creates the Fly app | `ssh -J gate@ssh.cmux.dev …` works for a team with the gate on and is refused for a team with it off |
| S13 | IdP group sync: SSO or SCIM groups map to node roles in `TeamDO`; the reconciler applies them through S4 | backend (with the enterprise lead) | S4, enterprise SCIM | removing a user from an IdP group removes the Linux group on the next directory event |
| S14 | drills: restore to a new VM (replay the journal onto local disk, then start apps), kill after acknowledge, revocation cuts live sessions (KRL push plus `pkill -u` of sessions with the revoked key id), wake budget p95 | test scripts on `cmuxnp-dev-` resources | all | the P15 "done when" holds with evidence |

Phase 3b roadmap row (spec-coverage P15): S2, S3, S4, S6 and S7 are phase 3b. S11 to S13 follow.

## 4. Storage spike design (S1, done; JuiceFS rejected, kept for the record)

Goal: decide whether JuiceFS (no writeback, data in R2, metadata in Postgres) is the zero-loss tier on Freestyle, with numbers, before any mount code lands.

Resources (all named `cmuxnp-dev-teamfs-*`, ids recorded in `.cmux-scratch/nx-worker/team-vm/resources.txt`, deleted by id after the spike):
- `cmuxnp-dev-teamfs-data`: Freestyle VM from `freestyle/ubuntu-sm`, `fuse3`, `acl`, `auditd`, JuiceFS (pinned release, checksum checked), `ripgrep`, `sqlite3`, `git`.
- `cmuxnp-dev-teamfs-meta`: a second Freestyle VM that runs Postgres 17 as the phase A metadata engine. It is off the data VM, so deleting the data VM is a real loss test. Phase B replaces it with `cmux-teamfs` development.
- `cmuxnp-dev-teamfs-spike`: an R2 bucket on the cmux account (location hint `wnam`), or a `cmuxnp-dev-teamfs-spike/` prefix if the available token cannot create buckets (recorded as a shortcut).
- A second data VM `cmuxnp-dev-teamfs-data2` for the restore step.

Measurements (each p50, p95, max, n):
1. Capabilities: FUSE mount as root with `allow_other`; `setfacl`/`getfacl` with access and default ACLs through the JuiceFS mount (needs `--enable-acl` at format); setgid inheritance; umask; supplementary groups of a non-root user; inotify events for writes on the mount; `flock`; atomic `rename`.
2. Round-trip times from the data VM: R2 PUT and GET for 4 KiB, 64 KiB, 1 MiB; Postgres `SELECT 1` to the meta VM; Postgres `SELECT 1` to `cmux-next` development (read only, no schema change) as the stand-in for PlanetScale in region.
3. Write plus fsync for 1 KiB, 16 KiB, 256 KiB files; rename; 1,000 mailbox-style sends (write tmp, fsync, rename) at 1 and 8 writers.
4. Tasks group commit: the `cmux-tasks` store (op log, group commit) on the mount, single writer, 1 and 32 ops per batch; ops per second and commit latency.
5. `rg` over a generated 50,000-file markdown corpus (about 200 MB) and over a 10,000-file corpus: cold (fresh mount, empty cache), after `juicefs warmup`, warm, and after Freestyle pause and resume.
6. `git status` on a 50,000-file repo on the mount; `git commit` of 100 changed files.
7. Durability: a writer appends records with fsync and streams each acknowledged sequence number off the VM (through the exec stream to the laptop log) as soon as fsync returns. The data VM is deleted mid-stream (not paused). `data2` mounts the same volume and checks every acknowledged record by hash. Pass: zero missing acknowledged records over 3 runs. Also kill the JuiceFS client with SIGKILL mid-write and remount.
8. Control: `npm install` of a medium project on the mount vs local disk (confirms the tier split; not adopted).
9. Costs: R2 operations count and Postgres row counts per 1,000 sends, for the per-team cost estimate.

Go criteria (proposed): durability test zero loss; ACLs, setgid and inotify work through the mount; mailbox send p95 under 250 ms; Tasks group commit p95 under 250 ms; warm `rg` over 10,000 files under 1 s. If durability or ACLs fail, the D36 fallback applies (git with synchronous push, synchronous catalog write paths) and the Freestyle ask list (lane 12's email) already covers FUSE. If only latency fails, the plan tries a closer metadata region, then the cmux-built journal from the research file.

Output: `plans/cmux-next/team-vm-spike.md` with numbers, method, and the go or no-go, plus the scripts under `scripts/cmux-next/team-vm-spike/` so phase B and later regressions rerun the same steps.

## 5. Security notes the slices must carry

1. Per-team isolation. With the DO journal, the VM holds no R2 or database credential: it calls `TeamVmDO` with its install token, and the DO writes only its own team prefix. If a VM ever needs direct R2 access (bulk restore), it gets a temporary credential scoped to `teams/<team>/` (O1, verified in the spike).
2. Credentials on the VM are root-only. Nobody has `sudo` in normal operation (spec), so agents cannot read them; the break-glass path is logged.
3. The SSH CA private key never leaves `TeamDO` in clear; it is sealed under a Worker secret like the SSO secrets (`INTEGRATIONS_KEK` pattern).
4. A restored VM gets a new epoch. The old VM's install token is revoked at restore, and `journal.append` refuses the old epoch (a stale writer cannot commit).

## 4a. Journal store (measured 2026-10-03, from a Freestyle VM in San Francisco)

| Candidate | Measured | Commit estimate |
| --- | --- | --- |
| Durable Object behind the API Worker (staging, colo SJC) | Worker only 8.5 ms p50, 9.7 ms p95; Worker plus a DO read 17.2 ms p50, 20.0 ms p95 (n = 20) | about 20 to 30 ms with the durable storage write |
| PlanetScale us-west-2, one `INSERT` on an open connection | TCP RTT 33 ms | about 35 to 40 ms; needs `cmux-teamfs` (on hold) and a database credential on the VM |
| R2 PUT with a create-if-absent condition | 214 ms p50, 289 ms p95 (4 KiB) | about 215 to 300 ms; needs an R2 credential on the VM |

Choice: the DO (`TeamVmDO`, tag v13), because it is the fastest, it is already the team's single writer for routing and the epoch, and the VM needs no database or R2 credential (the DO writes R2 segments through its binding). Strongest objection: the journal path now depends on Cloudflare reachability from the VM, and a DO has a storage limit per object. Answer: writes fail visibly when the API is unreachable (no silent loss, U5), and compaction to R2 segments keeps the DO small; one DO per team handles the expected write rate (Tasks groups commits). `cmux-teamfs` is not needed and can be cancelled.

## 5a. Spike result (2026-10-03)

Phase A (team-vm-spike.md): every capability passes through the JuiceFS mount, and O1 isolation works, but latency fails every go criterion. A raw R2 PUT from Freestyle (San Francisco) takes 214 ms p50, and PlanetScale us-west-2 is 33 ms away, so write plus fsync is 259 ms p50 with nearby metadata and 810 ms with PlanetScale; warm `rg` over 10,000 files takes 14 s (ext4 under 0.1 s). The recommendation is the D36 path: local ext4 for files, a synchronous journal for the acknowledged write paths (Tasks Replica, `team.mail.send`, `team.memory.write`), seconds of recovery point for plain-tool edits. This changes the zero-loss promise, so it waits for Lawrence; `cmux-teamfs` creation is on hold.

Requirement for lane 10 (app supervisor): `CMUX_APP_HOST` on the team VM is the per-instance metadata instance id, never a value that a cloned image shares (Tasks lead, epoch fence).

## 6. What Lawrence must create (cancelled for the zero-loss tier: the DO journal needs no new database or bucket; R2 segments go to the existing backend bucket binding chosen by the backend lead) (exact commands go to main, not run by this lane)

1. PlanetScale database `cmux-teamfs` (D35), org `cmux`, region `us-west` (same as `cmux-next`): production branch `main` highly available (`PS-5-AWS-ARM`, 2 replicas, about $15 per month by `pscale size cluster list`), branches `staging` and `development` at the default development size. One admin role per branch for the control plane, written to `~/.secrets/cmux-teamfs-planetscale-<branch>.env` without printing. Commands: `.cmux-scratch/nx-worker/team-vm/lawrence-create-teamfs.md`.
2. R2 buckets `cmux-teamfs-development`, `cmux-teamfs-staging`, `cmux-teamfs-production` (location hint `wnam`) and the audit bucket lock rule, plus an API token that can mint temporary credentials for those buckets. Same file.
3. Later (S12, not needed now): Fly.io app for the gate in region `sjc` with a dedicated IPv4 and IPv6 and the DNS name `ssh.cmux.dev`. Commands come with S12.

## 7. Open items and decisions for Lawrence (through main)

- O1 ANSWERED YES (2026-10-03) and verified in the spike: prefix-scoped R2 temporary credentials minted by `TeamVmDO` plus one Postgres role per team schema, because a shared environment key lets one team VM read every team's files. Alternative: one R2 bucket per team (simple isolation, but bucket count limits per account and more provisioning).
- O2 moot: `cmux-teamfs` is not needed after the D36 decision and the DO journal choice.
- O3 for the server lane, not Lawrence yet: team app Postgres on local disk is not zero-loss. Tasks avoids it (op log). Other team apps that need zero loss must write their durable state through the app data directory or `cmux app data commit` (server.md 7). To be stated in the app platform docs.
- O4: R2 object versioning. The spec names it as the second line. The spike checks what the bucket supports; if versioning is not available, the second line is bucket lock rules on the audit prefix plus Freestyle snapshots.
- DO migration tag for `TeamVmDO`: v13 (assigned by the worker, recorded by the backend lead).
- O5 DECISION (to Lawrence through main): the zero-loss promise under D36. Files written through cmux ops and the Tasks log are zero-loss; plain-tool edits have a recovery point of seconds.

## 8. Risks

- The API Worker and `TeamVmDO` are a dependency of every acknowledged write. An outage blocks those writes (correct for zero loss, visible as errors); plain-tool edits continue locally and ship when the path returns.
- The journal must be fenced by the `TeamVmDO` epoch, or a paused old VM that resumes after a restore could write. S2 and S6 own that fence.
- Mailbox and memory move from a shared account on `cmux-lawrence` to per-principal Linux users; agents that hard-code the old path break at cutover (S11 keeps a read-only copy and a redirect note).
