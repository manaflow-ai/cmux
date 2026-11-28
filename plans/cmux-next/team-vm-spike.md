# Team VM storage spike, phase A (S1)

Status: done 2026-10-03 (team VM lead). Plan: team-vm-plan.md section 4. Result: **no-go for JuiceFS as the zero-loss tier on Freestyle**, on latency. Capabilities pass. Recommendation in section 5.

## 1. Setup

- Two Freestyle VMs (`freestyle/ubuntu-sm`, 2 vCPU, 4 GiB, Ubuntu 24.04, kernel 6.1.102) in one private network: `data` (JuiceFS 1.4.1 client, checksum verified) and `meta` (Postgres 16, `synchronous_commit = on`) as the metadata engine, off the data VM.
- Data: one R2 bucket on the cmux account (location hint `wnam`), JuiceFS volume prefix `teamfs-t1/`, accessed only with a prefix-scoped R2 temporary credential (session token).
- Mount: no writeback, `--open-cache 3600 --attr-cache 3600 --entry-cache 3600 --dir-entry-cache 3600`, 4 GiB local cache, `--enable-acl` at format.
- The PlanetScale case: the network has no `netem`, so a TCP proxy on the data VM added 16.5 ms each way to the metadata connection (measured `SELECT 1` 35 to 42 ms, the same as PlanetScale us-west-2 from Freestyle).
- Scripts: `scripts/cmux-next/team-vm-spike/` (`data-setup.sh`, `caps.sh`, `bench.py`, `r2put.py`, `delayproxy.py`). All resources were `cmuxnp-dev-teamfs-*` and were deleted after the run.

## 2. Network facts (from the data VM)

Freestyle VMs egress in San Francisco (AS36320).

| Target | TCP connect p50 |
| --- | --- |
| Cloudflare edge (colo SJC) | 6.5 ms |
| R2 endpoint | 8.7 ms |
| AWS us-west-1 (N. California, EC2 endpoint) | 9.3 ms |
| PlanetScale us-west-2 (Oregon, the `cmux-next` host) | 33 ms |
| PlanetScale gcp-us-central1 / aws-us-east-2 / aws-us-east-1 | 65 / 70 / 82 ms |
| Postgres on the meta VM (private network) | 0.6 ms |

R2 object latency, one keep-alive connection, n = 30:

| Size | PUT p50 / p95 | GET p50 / p95 |
| --- | --- | --- |
| 4 KiB | 214 / 289 ms | 110 / 123 ms |
| 64 KiB | 212 / 260 ms | 115 / 139 ms |
| 1 MiB | 291 / 461 ms | 163 / 273 ms |

PlanetScale offers no region nearer than us-west-2 to Freestyle.

## 3. Capabilities (all pass through the JuiceFS mount)

POSIX access and default ACLs (`--enable-acl`), the spec's node example (write by the project role, read-only by team readers, refusal for others), default ACL inheritance into new subdirectories, setgid on node directories, the mailbox inbox mode 1733 (others drop files but cannot list), inotify `close_write` on the mount, `flock` exclusivity, atomic `rename`, user xattrs. A metadata outage returns `EIO` to writers (no silent loss).

Per-team isolation (decision O1) verified: a temporary credential scoped to `teams/t1/` writes its own prefix and gets AccessDenied for another team's prefix (write and read) and for a list of the root. JuiceFS accepts the session token.

## 4. Latency and throughput

All values in ms unless noted. "JuiceFS local meta" = metadata 0.6 ms away; "JuiceFS PlanetScale RTT" = metadata 33 ms away.

| Test | ext4 local disk | JuiceFS local meta | JuiceFS PlanetScale RTT |
| --- | --- | --- | --- |
| write + fsync 1 KiB p50 / p95 | 0.9 / 1.2 | 259 / 352 | 810 / 1128 |
| write + fsync 256 KiB p50 / p95 | 2.3 / 3.8 | 292 / 405 | 793 / 933 |
| rename p50 | 0.03 | 8 | 647 |
| mailbox send (tmp, fsync, rename), 1 writer p50 / p95 | 1.0 / 1.1 | 265 / 325 | 1443 / 1558 |
| mailbox sends per second, 8 writers | 3,972 | 29 | not run |
| op log group commit, 1 op p50 / p95 | 0.9 / 1.1 | 223 / 349 | 467 / 789 (max 4.1 s) |
| op log group commit, 32 ops p50 (ops/s) | 1.3 (23,881) | 221 (145) | 464 (69) |
| create 50,000 files, 64 threads | 16 s | 1,245 s (40 files/s) | not run |
| `rg` over 10,000 files, warm | (50k: 0.75 s) | 14 to 18 s | not run |
| `rg` over 10,000 files, cold | | 313 s | not run |
| `rg` over 50,000 files, after `juicefs warmup` (137 s for 157 MiB) | 0.75 s | 49 to 51 s | not run |

The op log rows use a stand-in (append about 300-byte records, one fsync per group commit), not the `cmux-tasks` binary.

Why: each fsync uploads at least one R2 object (PUT floor about 214 ms from Freestyle), and each JuiceFS metadata change is several Postgres round trips (rename went from 8 ms to 647 ms when the RTT went from 0.6 to 33 ms). Warm reads were cached on local disk and still cost about 1.4 ms per file through FUSE on 2 vCPUs, so `rg` is about 65x slower than ext4 even when warm. The spec's estimates (30 to 120 ms per write, 0.2 to 0.6 s warm `rg` over 10k files) were too optimistic by 3x to 50x.

Against the go criteria (plan section 4): mailbox send p95 under 250 ms fails (325 local meta, 1,558 PlanetScale); Tasks commit p95 under 250 ms fails (349 / 789); warm `rg` over 10,000 files under 1 s fails (14 s). Not run because the design failed on latency: the kill-after-fsync durability test, `rg` after pause and resume, the git benchmarks.

## 5. Recommendation (D36 path)

Agents keep team files on the VM's local ext4 disk, so `rg`, git and editors run at local speed. Zero loss comes from a synchronous journal on the acknowledged write paths, not from the filesystem:

1. Tasks: the store's `Replica` hook (cmux-tasks `store/durability.rs`) ships each group commit to the journal before it replies; create-if-absent keyed by seq, epoch in the body.
2. Mailbox and memory through the catalog (`team.mail.send`, `team.memory.write`, `cmux team mail send`): the op commits the file content to the journal, then writes the local file, then returns.
3. Plain-tool edits (an agent edits a memory file with an editor): the journal service (inotify, debounced) ships the change within seconds. These writes have a recovery point of seconds, not zero. Freestyle snapshots stay the second line.
4. Restore: a new VM replays the journal onto local disk, then starts apps.

Journal store candidates to measure next (from Freestyle SF): a Durable Object pinned near SJC (edge 6.5 ms; estimate 10 to 30 ms per commit), a single `INSERT` to PlanetScale us-west-2 (estimate 35 to 40 ms), an R2 conditional PUT (measured 214 ms p50). If the DO path holds, `cmux-teamfs` on PlanetScale is not needed for the zero-loss tier.

For true zero loss of plain-tool writes, a FUSE passthrough journal (local ext4 plus one synchronous journal write per fsync) remains possible later; it is a larger build and not required for the first release.
