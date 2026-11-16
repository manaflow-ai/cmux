# Rust allocator follow-up for acpmux

Rust 1.100 makes the allocator API stable for `Vec` and `Box`. It does not make
`String`, maps, or `serde_json::Value` arena-backed automatically. The paths below
are candidates for a bounded arena or reusable slab, but this note deliberately
lands no allocator change.

| path | candidate | current evidence | opportunity to measure |
| --- | --- | --- | --- |
| Journal replay (`acpmux/src/store/journal_store/repair.rs`, `journal_store.rs`) | Store record payloads in a byte slab and keep offset/length pairs. | Each record currently carries a chat id and line buffer. | At 1M records, replacing a 24-byte `Vec<u8>` descriptor with an 8-byte pair models **15.3 MiB** of descriptor savings. A second **15.3 MiB** is only an illustrative allocator-overhead model; payload bytes remain required. |
| Transcript decode (`acpmux/src/store/log_line.rs`, `store/kind_index.rs`) | Decode borrowed records against a per-line or per-replay arena. | A token fixture creates about **19 owned string allocations** before map nodes. | At 1.33M records, that is roughly **25M string allocations** to eliminate or coalesce. The decoded representation must change; wrapping the outer `Vec` is insufficient. |
| Transcript suffix restoration (`acpmux/src/hub/bounded.rs`, `hub/turns.rs`) | Coalesce tiny chunks or use a reusable ring. | A 24,000-character suffix can retain 24,000 one-character `String` descriptors. | The descriptors alone model **562.5 KiB** for **23.4 KiB** of ASCII payload. A whole-transcript bump arena would retain evicted chunks, so bounded reuse is preferred. |
| Row-book pages (`acpmux-book/src/log/read.rs`, `log/recover.rs`) | Keep the existing caller-owned scratch buffers. | Pages are capped at 256 KiB, frames at 1 MiB, and recovery scratch at 128 KiB. | There is no evidence that an arena would improve this already bounded path. |

The catch-up path also deserves an RSS measurement before any allocator design:
the 1.5M-record fixture accumulates at least **1,300,026** patches before its 2 MiB
retention cap. A conservative 64-bit layout model puts the enum slots at **at least
367 MiB**, excluding strings and spare capacity. The existing fold benchmark clears
its output after every record and therefore does not measure this production peak.

## Validation gate

Run the same Linux runner, Rust toolchain, profile, and fixtures before and after:

```sh
cargo test -p acpmux-book --release --lib god_vs_small -- --ignored --nocapture
cargo test -p acpmux --release --lib rows::bench -- --ignored --nocapture
cargo test -p acpmux --release --lib bench_adopt_open_of_a_420_mb_transcript -- --ignored --nocapture
```

Add journal replay at 1k/100k/1M records, transcript chunks of 1/8/64 bytes, and
legacy row catch-up. Capture allocations, allocated bytes, peak live bytes/RSS,
p50/p95 latency, and output equality. Do not land an allocator change unless it
shows at least **10% p95 latency** or **20% peak-memory** improvement, preserves
output, and does not grow across repeated open/page/close cycles.
