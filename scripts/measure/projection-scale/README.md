# projection-scale: RFD 0065's measurement matrix on one harness

RFD 0065 piece 14. One script, `measure.py` (Python stdlib, Linux), runs the serve/link/mount and clone
matrix RFD 0065 measured by hand (its `projection-measure.md` and `git-measure.md`), so each projection PR
reports before and after from the same harness. It is registered as the `projection-scale` bench, so
`cmux-bench compare` reads two runs.

## Projection

```sh
# the projected tree: slice_bench serve -> link (byte/ask counter) -> mount (the real FUSE overlay)
scripts/measure/projection-scale/measure.py projection TREE --out out
# the same steps on TREE itself, the baseline
scripts/measure/projection-scale/measure.py projection TREE --mode plain --out out
# the link held at a profile's rate and RTT (slice_bench link --mbps / --rtt-ms)
scripts/measure/projection-scale/measure.py projection TREE --profile github-v4-bad --out out
```

`slice_bench` is cmux-projection's bench example. The script uses `--bin PATH`, else
`$CARGO_TARGET_DIR` (or `cmux-tui/target`)`/release/examples/slice_bench`, building only that example
(`cargo build --release -p cmux-projection --example slice_bench`) when it is missing or with `--build`.

Per step (`--steps ls,rg,gitstatus`: `find . | wc -l`, `rg -c the .`, `git status --porcelain`) it mounts
fresh (new mount and state dir), drops the page cache when `sudo -n` works, runs the step cold, then warm.
Rows: `serve_start` (walk, manifest size), `mount_<step>` (seconds to mounted, manifest bytes),
`<step>_cold`, `<step>_warm` (seconds, bytes down and up the link, asks = writes up, the mount's RSS), and
`<step>_overlay_stats` (the overlay's remote reads, bytes, cache hits at unmount).

## Git clone options

```sh
scripts/measure/projection-scale/measure.py git REPO [--branch B] [--cone dir1,dir2] \
  [--options depth1,blobnone,treeless,sparse,gitzst,overlay] --out out
```

It serves one branch of REPO from a local `git daemon` (git://, `uploadpack.allowFilter`), clones with a clean
`HOME` and `GIT_CONFIG_NOSYSTEM=1`, and records wall seconds, bytes received (the growth of
`.git/objects/pack`, so what any link must carry), `.git` and worktree bytes, and the first and second
`git status`:

| option | command |
|---|---|
| depth1 | `git clone --depth 1` |
| blobnone | `git clone --filter=blob:none` (all commits and trees, tip blobs at checkout) |
| treeless | `git clone --filter=tree:0` |
| sparse | `git clone --depth 1 --filter=blob:none --sparse`, then `sparse-checkout set CONE` (a `widen` row) |
| gitzst | `tar .git \| zstd -3 -T16` of a depth-1 clone (a `pack` row), then unpack and `checkout -f` with `checkout.workers=16`; bytes = archive size |
| overlay | `mount -t overlay` with a depth-1 checkout as lowerdir (needs `sudo -n`; else a "not measured" row); bytes 0 |

## Link profiles (RFD 0067)

`measure.py profiles` lists them. A row measured on the uncapped local link gets one projected-seconds
column per profile: local seconds + bytes down / rate + asks x RTT (asks are a floor of round trips; git rows
count no asks). `--profiles a,b` picks the columns.

| profile | MB/s | RTT ms | source |
|---|---|---|---|
| github-v4-bad | 0.14 | 67 | GitHub, one IPv4 stream, Freestyle's bad hour |
| github-v4-good | 0.47 | 67 | the same an hour later |
| store-v6-1-low | 22 | 5 | our store, one IPv6 stream, low end |
| store-v6-1-high | 43 | 5 | one IPv6 stream, high end |
| store-v6-8 | 131 | 5 | 8 IPv6 streams (131-139 MB/s) |

`projection --profile NAME` instead runs the link itself at that rate and RTT, a real throttle on the
projection's wire (no `tc`: it would throttle the whole host's loopback).

## Output

Every row is appended to `OUT/rows.jsonl`; the run prints the table as TSV, or Markdown with `--markdown`.
`measure.py table OUT [--markdown]` prints it again, for several runs at once.

```sh
scripts/bench/cmux-bench projection-scale --import out/rows.jsonl --build local   # record a run
scripts/bench/cmux-bench projection-scale --host anywhere --arg kind=projection --arg tree=TREE
scripts/bench/cmux-bench compare <before run> <after run> --markdown
```

## Hill climb (the transport knobs)

```sh
scripts/measure/projection-scale/hillclimb.py TREE --profile store-v6-1-low --steps rg,gitstatus --out climb
```

`hillclimb.py` turns the knobs cmux-projection reads from the environment (`src/tune.rs`): the packed
answers' zstd level (`CMUX_PROJECTION_ZSTD_LEVEL`, `0` = raw) and the read-ahead caps
(`CMUX_PROJECTION_READAHEAD_FILES`, `CMUX_PROJECTION_READAHEAD_BYTES`). It starts at the shipped defaults,
tries each knob's next value up and down, keeps a move only when the cold steps' summed seconds on the
throttled link drop by more than 3%, and stops when a round moves nothing. `OUT/climb.jsonl` has every try,
`OUT/best.json` the winner and its gain over the defaults. Unset, the knobs keep the defaults; a winner
becomes a default in its own PR with the climb's numbers. Tests: `scripts/measure/tests/projection-hillclimb.test.py`.

## What it does not do

- The big trees (cmux, linux, the 1 M file synthetic) are not run here: give it the tree. RFD 0065's numbers
  came from a shared busy host; run before and after on the same host, alone.
- The `cmux-projection git-mount` mode and the build step of `projection-measure.md` are not wrapped yet.
- A full clone against the local daemon needs a full-history REPO; a blob:none mirror cannot serve it.
