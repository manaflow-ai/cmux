# The first slice, measured (RFD 0007)

One machine reads a folder that lives on another machine through `cmux-projection`, with no copy step,
against today's way: rsync the folder, then work on the copy. `../bench-slice.sh` produced every number here;
`slice-2026-11-22.jsonl` holds one row per arm per run.

## Setup

- Machine: a Cloud lane VM, Ubuntu 24.04, kernel 6.1.102 (the kernel Cloud machines ship), FUSE 3.14,
  32 cores, ext4. Other lanes build on it, so each row records the 1-minute load.
- Origin: a stand-in for the Mac, a process on the same VM serving the folder over TCP. No Mac was in the
  path; the link is modelled by `slice_bench link`: 50 ms round trip, 400 Mbit/s each way. Both arms cross
  the same model.
- Folder: `git archive` of this repo at 475153b0e08: 57,001 files, 1.28 GB, no `.git`, `target/` or
  `node_modules`.
- Builds: `cargo build -p cmux-projection --offline -j 16` (120 crates; dependencies come from the machine's
  own registry cache in both arms) and `bun install && bun run build` in `cmux-tui/bindings/typescript`.
- The mount binary is a release build. Caches are dropped before each arm.

## Results: 50 ms, 400 Mbit/s, median of 5 runs

| | Projected | Copy, then work |
| --- | --- | --- |
| Before the first command can run | 0.12 s (mount) | 28.5 s (rsync) |
| Bytes over the link by the end of all steps | 14.3 MB | 1,280 MB |
| First read of one file (24 KB) | 71.5 ms | 6.6 ms |
| The same file again | 6.7 ms | 5.1 ms |
| Again after dropping the page cache | 8.6 ms | 6.4 ms |
| `find .`, 62,546 entries | 1.11 s, 0 bytes over the link | 0.56 s |
| 20 files never read before | 190 ms | 49 ms |
| `cargo build`, cold, `target/` in the tree | 34.2 s | 22.8 s |
| `cargo build`, cold, `target/` on local disk | 31.3 s | n/a |
| `cargo build` after a one-line edit | 2.9 s | 1.5 s |
| `bun install` | 0.36 s | 0.03 s |
| `bun run build` | 4.3 s | 3.7 s |
| **Start to first build done** | **34.4 s** | **51.8 s** |

The copy arm's median excludes nothing; its third run met a load of 29.8 and took 34.6 s to build (row 6).

## Results: 50 ms, 4.4 Mbit/s, one run

The uplink RFD 0007 measured from a home connection. Rows in `slice-slow-link-2026-11-22.jsonl`.

| | Projected | Copy, then work |
| --- | --- | --- |
| Before the first command can run | 1.5 s (mount; the 771 KB listing takes 1.46 s) | 2,381 s (rsync, 39.7 min) |
| Bytes over the link by the end of all steps | 14.3 MB | 1,280 MB |
| First read of one file (24 KB) | 621 ms | 13.5 ms |
| The same file again | 7.8 ms | 4.5 ms |
| 20 files never read before | 5.4 s | 61 ms |
| `cargo build`, cold, `target/` in the tree | 39.8 s | 22.1 s |
| `cargo build` after a one-line edit | 3.2 s | 1.5 s |
| `bun run build` | 7.4 s | 3.6 s |
| **Start to first build done** | **41.4 s** | **2,403 s (40.0 min)** |

On this link the copy is 58 times slower to a finished build; the projected build loses 5.6 s to the
slower link against the fast one.

## What the numbers say

- The projection wins the whole job (34.4 s against 51.8 s) and moves 1.1% of the bytes, on a folder small
  enough to copy in half a minute. The copy's cost grows with the folder; the mount's does not (0.12 s for
  a 771 KB listing).
- A build on the mount is 11.4 s slower than on a copy. 3 s of that is writing `target/` through FUSE
  (34.2 s against 31.3 s with `target/` on local disk). The other 8.5 s is first reads: the build fetched
  266 files (4.1 MB) in 161 round trips. 8.5 s over 161 is 53 ms each, what a 50 ms link costs when
  the asks run one after another. Whether they did run one after another is not measured here; the
  arithmetic fits. The bytes are not the cost.
  (`slice-round-trips-2026-11-22.jsonl`: two more projected runs with the link counting writes going up,
  160 and 161 round trips in both.)
- The overlay already fetches a faulting file's small siblings in the same ask (`Overlay::whole`), which
  is why 266 files took 161 asks and not 266. What is left is one round trip per directory the build
  enters. So the next gain is reading ahead across directories: on a fault, also ask for the small files
  of the folders under the same crate, or replay the working set a previous build recorded.
- Warm reads cost the same as local disk within 2 ms, including after the page cache is dropped (the blob
  cache on disk answers).

## Not measured here

A real Mac as the origin (a lane VM cannot reach one), a real WAN, a folder with `.git`, the product path
through the two daemons (`cmux link project serve`), and write-back. RFD 0007 has the 107 GiB run from a
real Mac.
