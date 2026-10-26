# cmux NEXT memory: Memory Saver, budgets from RAM, one coordinator per process

Owner: PL-memory. Program spec: [chrome-parity/p07-memory.md](chrome-parity/p07-memory.md). Sections 1 to 10
(Chrome mapping, budgets, consumers, release rules, discards, processes, measurement, done checks, rules,
decisions) come with task 007; this commit adds section 11.

## 11. Kernel compressor and cold scrollback (task 112, gates 040 and 041)

Question: would a cmux codec for cold scrollback (040: serialize ghostty-vt pages with the deflate already in
cmux-tui's dependencies; 041: compress terminals with no viewer and no output for `cold_scrollback_after`) keep at
least 2x fewer bytes than the macOS memory compressor (WKdm, with LZ4 on Apple silicon) keeps for the same idle
terminals? Chrome does not compress its own state in user space on macOS: idle pages are left to the kernel
compressor (`docs/memory/key_concepts.md`; Blink's `MemoryPurgeManager` purges caches, it does not compress them).
cmux follows Chrome unless the measured gain is at least 2x.

### Method

`scripts/cmux-next/bench_memory.py --cold-scrollback 100` (the phase is in `scripts/cmux-next/cold_scrollback.py`),
run alone on an exclusive fleet mini (nothing else allocating, so the compressor's growth is this run's):

```
python3 scripts/cmux-next/bench_memory.py --app "<cmux DEV TAG.app>" --cold-scrollback 100 \
    --cold-scrollback-mb 10 --cold-idle 0,10,30 --cold-codec-samples 5 --out cold-scrollback.json
```

1. Base: `footprint -j` of the app, the cmux-tui daemon and its terminal hosts or holders; `vm_stat`.
2. 100 workspaces, one terminal each. Each terminal prints 10 MiB of seeded log-like text (timestamps, SGR colors,
   paths, hashes; every line under 80 columns), more than its 10 MB `scrollback-limit` holds, so each ends with a
   full scrollback. The launch sets `terminal.scrollback.maxTotalMemoryBytes` to 2 x 100 x 10 MB so the daemon's
   scrollback budget trims nothing.
3. The first workspace is shown again: every cold terminal is hidden, with no viewer and no output. The bench
   samples at 0, 10 and 30 min idle and touches nothing in between (footprint reads regions; it pages nothing in).
4. After the last sample: the daemon's `read-scrollback` of 5 terminals (styled rows: the text and style runs 040
   would serialize), deflated at level 6 (flate2's default). Reading pages the rows back in, so it runs last.

Per cold terminal, over the base, for the daemon (it keeps the VT pages; hosts and holders keep a PTY and a byte
ring, reported in their own column and left out of the gate):

- dirty: resident dirty bytes;
- compressed: bytes in the compressor, at their uncompressed size (as footprint and phys_footprint count them);
- kernel ratio: stored / occupied compressor pages from vm_stat over the base when this run's compressed bytes are
  at least half of what the compressor took in (`delta`), else the whole compressor's ratio (`system`);
- kernel all-cold: (dirty + compressed) / kernel ratio, what the kernel holds at best once every cold byte is
  compressed;
- deflate: the mean deflated size of the read-back scrollback.

Gain = kernel all-cold / deflate at the last idle point. Go for 040 and 041 only if gain >= 2. Without a kernel
ratio or a read-back the run decides no-go, and 040/041 stay off.

The bench prints `COLD-SCROLLBACK idle_min=...` per sample, `COLD-SCROLLBACK-DECISION go=... gain=...`, and the
table below; paste it here with the host, macOS version, RAM and app commit.

### Result

Host, macOS, RAM, commit: not measured yet (test phase: fleet exclusive measurement).

| idle min | dirty MiB | compressed MiB | kernel ratio (source) | kernel now MiB | kernel all-cold MiB | hosts MiB | app MiB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | - | - | - | - | - | - | - |
| 10 | - | - | - | - | - | - | - |
| 30 | - | - | - | - | - | - | - |

Deflate per cold terminal: not measured yet.

### Decision

No-go until the table above has a fleet run: 040 and 041 are not built, and `cold_scrollback_after` compresses
nothing. The run's `COLD-SCROLLBACK-DECISION` line replaces this paragraph, with its gain.

Notes for reading the run:

- phys_footprint (Activity Monitor's Memory) counts compressed pages at their full size, so the kernel compressor
  lowers physical memory use but not the footprint people see; a codec lowers both. The gate compares physical
  bytes, as Chrome's choice does; the footprint column is recorded for the decision, not used by it.
- Without memory pressure macOS rarely compresses an idle process's pages; if the 30 min sample shows no
  compressed bytes, the kernel ratio is the `system` one, and the gain is what the kernel would reach under
  pressure.
- The read-back serialization is text and style runs, the least 040 has to keep; 040's own acceptance (ratio >= 8x
  on terminal_corpus and kitty fixtures) checks the real codec.
