# Event-log batching evidence (#12984)

The issue reported per-line FileHandle writes during agent/feed bursts. The incident's app-wide CPU/footprint numbers also include other subsystems; this change proves reduced write amplification in `CmuxEventLogWriter`, not resolution of that entire incident.

## Reproduction and fix

The red checkpoint `c4881822f28ade0934a512ee154514c9838a2922` adds only constructor injection for the synchronous physical write and the behavior tests, leaving the per-line algorithm intact. Against that checkpoint, 32/256/1024-record batches issue 32/256/1024 calls. The focused Swift Testing run failed with 11 assertions; exact bytes, ordinary rotation layout, and the oversized-record policy were preserved already.

The fix keeps one `Data` buffer for the current file segment, writing it before rotation and at batch end. UTF-8 plus newline bytes count toward the same limit. The existing utility queue, enqueue scheduling, 1,024-line cap, drop-oldest behavior, drop diagnostic, open/close lifecycle, and error diagnostic remain unchanged. No periodic flush, producer change, or main-actor I/O was introduced.

## Measured results

Seven measured samples per workload after one warm-up, optimized Swift 6 build on macOS 26 / Apple Silicon. Every sample uses fresh synthetic files. Each record is about 955 bytes. Timing includes enqueue-to-drain scheduling after a deliberately suspended deterministic batch, directory/file opening, encoding, writing, rotation, and close; fixture generation and verification are outside the timer. It measures kernel-buffered writes, not fsync or physical-media durability.

| Submitted events | FileHandle write calls before → after | Median flush ms before → after | Dropped events before → after |
| --- | --- | --- | --- |
| 32 | 32 → 1 | 0.441 → 0.410 | 0 → 0 |
| 256 | 256 → 1 | 1.230 → 0.540 | 0 → 0 |
| 1024 | 1024 → 1 | 4.833 → 0.812 | 0 → 0 |
| 1152 | 1024 → 1 | 4.953 → 1.169 | 128 → 128 |
| 256 crossing 16 MiB | 256 → 2 | 2.225 → 0.991 | 0 → 0 |

The 1,152-event overload keeps the newest 1,024 records and drops 128 before flushing in both versions. No lower drop rate is claimed from this deterministic workload. Every sample checks byte-for-byte contents, complete parseable JSONL, FIFO record IDs, file-size/rotation boundaries, the sum of written bytes, off-main-thread writes, and drained/reset backlog accounting. Raw samples and toolchain details are in [12984-event-log-benchmark.json](12984-event-log-benchmark.json).

Reproduce from the clone root on an authorized Mac:

```sh
python3 scripts/benchmark-event-log-writes.py --baseline c4881822f28ade0934a512ee154514c9838a2922 --output /tmp/cmux-12984-benchmark.json
```

This compiles only the actual writer, test spy, and benchmark, without building or launching the app. The baseline includes the identical injected write dependency so observations have the same overhead.

## Behavior coverage and limits

`CmuxEventLogWriterTests` is wired into the app test target. Ten Swift Testing methods cover empty/single/32/256/1024-record batches, below/exact/across the real 16 MiB boundary, full-existing-log rotation, maximum-sized producer records, multiple rotations, UTF-8/newline byte accounting, oversized records, backpressure, and failures before/after rotation followed by recovery. The standalone focused run passes with warnings as errors. Full app target and hosted verification are tracked in the PR.

The extra buffer contains at most one log segment for ordinary records (normally at most 16 MiB); it is released after each append call. A single oversized record still writes whole, and the existing next-rotation cleanup discards that oversized active log. This pre-existing exception does not become a truncation or new drop policy. Rotation still retains only the active file and one archive, so multiple rotations retain the same last two segments.

A failed physical write still stops the append and logs an error without retrying or counting I/O failure as queue overflow. A coalesced call contains more records, so a failure can abandon a larger chunk. Partial-write/disk-full behavior and crash/power-loss durability retain FileHandle's existing limitations; no new fsync guarantee is claimed. No live app/session, UI dogfood, memory-pressure incident, or Intel/macOS 14 run was performed locally.

Localization audit: production diagnostics are unchanged; no user-facing strings or shortcuts were added. The existing production queue and locks stay at their current ownership boundary; the spy's test-only lock protects synchronous observations from that queue without adding async work to the timed I/O path.
