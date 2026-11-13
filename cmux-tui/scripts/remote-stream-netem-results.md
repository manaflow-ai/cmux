# TCP loss recovery measurements, 2026-11-12

Leo asked: “cmux-wg TCP under loss. A busy stream onto cmux-wg TCP has a frame p50 of 390 ms, against 25 ms at 50 ms RTT with 2% loss. Find the cause (likely head-of-line blocking or a send-buffer or Nagle setting) and root-fix it in Rust. Bring before/after numbers from the same netem harness. Do not turn transport.wireguard on by default.”

Congestion avoidance credited at most one MSS for each ACK, even when delayed
or cumulative ACKs acknowledged more bytes. Equal delivery therefore grew the
window about half as much with delayed ACKs: 479 bytes versus 240 bytes in the
fail-first regression. Crediting all newly acknowledged bytes fixes that loss
of recovery capacity. Slow start keeps its existing one-MSS cap. Nagle was
already disabled. No transport default changed.

Both revisions used `remote-stream-netem-bench.sh`: 60 fps, 3,500-byte frames,
200,000-byte first frame, 4,000,000-byte bulk transfer, three 8-second runs per
cell, loopback MTU 1500, segmentation offloads disabled, kernel netem delay
RTT/2 and independent packet loss. Table entries are medians of the three run
statistics, not percentiles recomputed from pooled frames.

| RTT / loss | Transport | Frame p50 ms before → after | Frame p95 ms before → after | On-time fps before → after | Bulk Mbit/s before → after |
| --- | --- | --- | --- | --- | --- |
| 50 ms / 0% | WG TCP | 31.46 → 31.42 | 32.91 → 32.52 | 58.4 → 58.5 | 28.61 → 28.74 |
| 50 ms / 2% | WG TCP | 839.97 → 52.92 | 984.43 → 291.89 | 0.1 → 42.9 | 1.68 → 2.11 |
| 50 ms / 0% | Kernel TCP control | 25.68 → 25.28 | 26.74 → 26.03 | 59.2 → 59.2 | 74.00 → 71.42 |
| 50 ms / 2% | Kernel TCP control | 45.85 → 40.81 | 327.51 → 227.00 | 42.9 → 48.8 | 3.63 → 2.93 |
| 50 ms / 2% | Datagram control | 26.16 → 26.53 | 29.06 → 29.08 | 34.8 → 34.8 | — |

The clean stream is unchanged; the lossy stream's persistent backlog shrinks.
The ordered stream still waits behind lost bytes. This does not establish that
it matches datagrams or kernel TCP across all loss patterns. The three lossy
WG run p50s were 96.88/1084.07/839.97 ms before and 44.39/52.92/204.23 ms after:
random loss has substantial run-to-run variation. No 150 ms RTT, mobile, or
path-switch improvement is claimed by this run.

## Receipt and reproduction

Linux CI run [43308064561](https://github.com/manaflow-ai/cmux/actions/runs/43308064561),
job `6f245719e796460f96386246b39d3ebf`, tested head
`4cdbfaf9f34d1ef03bc36795fbf122d18e337e18` through snapshot
`4273488aa7fd5fb5f15c61d30cd87ef4fe66bfdb`; command exit 0, 537.816 seconds.
The CI host kernel omitted netem, so both builds ran inside one ephemeral
Linux 6.8.0-149-generic guest, 2 vCPUs and 2 GiB RAM, with software CPU emulation.
The controls above were measured in that same guest. These numbers replace
neither the original host's baseline nor a physical-device measurement.

`remote-stream-netem-ci.sh` reproduces the guest setup and paired command:

```sh
cmux-ci test --setup rust --timeout 2400 --artifact /tmp/netem-results -- \
  bash cmux-tui/scripts/remote-stream-netem-ci.sh
```

It reverses only the congestion-controller change for the baseline, and checks
that file's SHA-256 against the test-only revision
`54223b7663b8166f3e0239859a86188fbf94b36d`:
`bc3eacf894d32871c5be1ff093e3c79538a4d613a401503ffe83af23390eb99a`.
The fixed source SHA-256 is
`76e8acdd36279e7072b5b7200920ed9f2a3e18da342d42865db66bcdfbaecc05`.
The baseline test fails in run
[43304973214](https://github.com/manaflow-ai/cmux/actions/runs/43304973214).
The fixed source passes 473 stack tests and 118 transport tests in run
[43305514053](https://github.com/manaflow-ai/cmux/actions/runs/43305514053).

The 36 complete records are in `remote-stream-netem-results.jsonl`.
Their outer RTT/loss fields describe kernel netem; the inner zero RTT/loss
fields mean the benchmark's in-process impairment was disabled.
