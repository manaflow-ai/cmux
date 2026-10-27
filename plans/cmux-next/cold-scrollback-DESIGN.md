# cmux NEXT memory: kernel compressor and cold scrollback (task p07-memory-112, gates 040 and 041)

Owner: PL-memory. Program spec: [chrome-parity/p07-memory.md](chrome-parity/p07-memory.md). This is the
cold-scrollback part of the memory design. memory-DESIGN.md (task p07-memory-007) links to it when 007 lands.

Status: the harness is done; the measurement is not. The task stays open until a fleet exclusive run fills the
table below.

## Question

Would a cmux codec for cold scrollback keep at least 2x fewer bytes than the macOS memory compressor (WKdm, with
LZ4 on Apple silicon) keeps for the same idle terminals?

- 040: serialize ghostty-vt pages with the deflate already in cmux-tui's dependencies.
- 041: compress terminals that have no viewer and no output for `cold_scrollback_after`.

On macOS, Chrome does not compress its own state in user space. It leaves idle pages to the kernel compressor
(`docs/memory/key_concepts.md`). Blink's `MemoryPurgeManager` purges caches; it does not compress them. cmux does
the same as Chrome unless the measured gain is at least 2x.

## Method

Run `scripts/cmux-next/bench_memory.py --cold-scrollback 100` alone on an exclusive fleet mini. Nothing else may
allocate, so the compressor's growth is this run's. The phase is in `scripts/cmux-next/cold_scrollback.py`.

```
python3 scripts/cmux-next/bench_memory.py --app "<cmux DEV TAG.app>" --cold-scrollback 100 \
    --cold-scrollback-mb 10 --cold-idle 0,10,30 --cold-codec-samples 5 --cold-pressure 5 \
    --out cold-scrollback.json
```

1. The launch uses the holder terminal model. Under the hosts model, each `__terminal-host` runs its own ghostty-vt
   terminal. Its scrollback is `HostLaunch::host_scrollback(10 MB) = 10 MB`, a second full copy of the daemon's
   copy. 040 and 041 compress only the daemon's copy, so under the hosts model the run decides `not measured`. The
   bench refuses `--terminal-host-model hosts`, and it finds the model of an attached app from the processes that
   opening the terminals adds.
2. Base sample: `footprint -j` of the app, the cmux-tui daemon and its holders; `vm_stat`.
3. The bench opens 100 workspaces with one terminal each and shows the first workspace again. It then takes the
   control sample: every terminal is open and hidden, and every scrollback is empty. Growth past the control is
   what printing added. The Surface, the active screen, threads and buffers of each terminal are not in it.
4. Each terminal prints 10 MiB of seeded log-like text (timestamps, SGR colors, paths, hashes; every line under 80
   columns). That is more than its 10 MB `scrollback-limit` holds, so each terminal ends with a full scrollback.
   The launch sets `terminal.scrollback.maxTotalMemoryBytes` to 2 x 100 x 10 MB, so the daemon's scrollback
   budget trims nothing.
5. Samples at 0, 10 and 30 min idle. The bench touches nothing between them.
6. Real memory pressure: `memory_pressure -Q -p 5 -y 30` allocates until 5% of RAM is free, waits 30 s, then exits
   and frees its pages. This repeats at most 3 times, until the compressor holds at least half of the daemon's
   growth. A sample follows each run. On an idle Mac with free RAM, the kernel compresses almost nothing, so only
   this sample measures the compressor on scrollback pages. `-S` is not used: it only sets the level that the
   dispatch sources read, and the kernel then compresses nothing. `-l` is not used: it allocates and then waits
   with no exit.
7. Last: the daemon's `read-scrollback` of 5 terminals is deflated at level 6 (flate2's default). The rows are
   styled: the text and style runs that 040 would serialize. Reading pages the rows back in, so this step is last.

Per opened terminal, from the daemon's footprint over the control:

- dirty and compressed: resident dirty bytes and compressed bytes (at their uncompressed size, as footprint and
  phys_footprint count them);
- scrollback: the growth (dirty + compressed), up to the 10 MB scrollback-limit;
- other: the growth past the limit. This is allocator slack from parsing 1 GB of output. It stays resident under
  either choice, so it is not in the gate;
- kernel ratio: stored / occupied compressor pages from vm_stat over the control. The source is `delta` when this
  run's compressed bytes are at least half of what the compressor took in, else `system` (the whole compressor);
- kernel scrollback: scrollback / kernel ratio;
- deflate: the mean deflated size of the read-back scrollback.

Gain = kernel scrollback / deflate, on the pressed sample (on the last idle sample with `--cold-pressure 0`).
Go for 040 and 041 only when all of these are true: gain >= 2, the ratio source is `delta`, and at least half of
the growth is compressed. Otherwise the decision is no-go ("the compressor did not take the cold pages").

The decision is `not measured` (no-go, 040/041 stay off) when any of these is true:

- a terminal failed: no terminal in its workspace, a failed send, or no end marker within 30 min;
- the hosts model ran;
- a sample has no daemon category rows from footprint, or the daemon pid changed;
- the daemon grew less than half the scrollback-limit per terminal;
- there is no read-back to deflate, or no compressor ratio.

Known bias that stays: the codec side is text and style runs only, the least 040 must keep. 040's own acceptance
(ratio >= 8x on terminal_corpus and kitty fixtures) checks the real codec.

The bench prints `COLD-SCROLLBACK sample=...` per sample, `COLD-SCROLLBACK-DECISION go=... measured=... gain=...`,
and the table below. Paste them here with the host, macOS version, RAM and app commit.

`footprint -j` is parsed by `scripts/cmux-next/footprint_json.py`, which memory-report.py also uses. Its key names
come from fixtures. When a real capture from a fleet Mac is checked in as a test fixture, confirm them. A capture
that the parser cannot read gives invalid samples and `not measured`, never a gain.

## Result

Host, macOS, RAM, commit: not measured yet (test phase: fleet exclusive measurement).

| sample | valid | dirty MiB | compressed MiB | scrollback MiB | other MiB | kernel ratio (source) | kernel now MiB | kernel scrollback MiB | holders MiB | app MiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 min idle | - | - | - | - | - | - | - | - | - | - |
| 10 min idle | - | - | - | - | - | - | - | - | - | - |
| 30 min idle | - | - | - | - | - | - | - | - | - | - |
| pressed (5% free) | - | - | - | - | - | - | - | - | - | - |

Deflate per cold terminal: not measured yet.

## Decision

Not measured. 040 and 041 are not built, and `cold_scrollback_after` compresses nothing. The run's
`COLD-SCROLLBACK-DECISION` line replaces this paragraph, with its gain.

Notes for reading the run:

- phys_footprint (Activity Monitor's Memory) counts compressed pages at their full size. The kernel compressor
  lowers physical memory use, but not the footprint people see; a codec lowers both. The gate compares physical
  bytes, as Chrome's choice does. The footprint columns are recorded for the decision but not used by it.
- Under pressure the kernel can also swap compressed segments to disk. footprint counts swapped bytes with the
  compressed ones, so a swapped run looks like a high ratio. Check `vm_stat` swapouts in the raw report before
  you accept a go.
