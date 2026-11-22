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

## What the numbers say

- The projection wins the whole job (34.4 s against 51.8 s) and moves 1.1% of the bytes, on a folder small
  enough to copy in half a minute. The copy's cost grows with the folder; the mount's does not (0.12 s for
  a 771 KB listing).
- A build on the mount is 11.4 s slower than on a copy. 3 s of that is writing `target/` through FUSE
  (34.2 s against 31.3 s with `target/` on local disk). The other 8.5 s is first reads: the build faulted
  266 files (4.1 MB) one round trip each, and the compiler reads them one after another. 266 reads at
  about 32 ms is 8.5 s. The bytes are not the cost; the round trips are.
- So the next gain is fewer round trips, not more bandwidth: when one file in a directory faults, fetch
  its small siblings in the same ask. `Fetch::batch` exists for this; nothing calls it on a cold fault yet.
- Warm reads cost the same as local disk within 2 ms, including after the page cache is dropped (the blob
  cache on disk answers).

## Not measured here

A real Mac as the origin (a lane VM cannot reach one), a real WAN, a folder with `.git`, the product path
through the two daemons (`cmux link project serve`), and write-back. RFD 0007 has the 107 GiB run from a
real Mac.
