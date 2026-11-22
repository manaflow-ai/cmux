# Network-conditions baseline

The baseline of record for the cmux NEXT phone surfaces under bad links, from
`scripts/measure/ios-network-conditions.sh` (the cmux-fault link shaper, seeded and deterministic).
Every fix that claims a mobile speed-up compares against these rows, from the same script.

Duress: slow or lossy link (shaped), on a shared Linux CI runner; history at 1x, 10x and 100x.

Run it:

```
cmux-ci run --class exclusive --label measure --script scripts/measure/ios-network-conditions.sh \
  --ref SHA --arg n=5 --artifact .build/ios-network-conditions/report.json --timeout 7200
```

Run: `lane-gh ci` on the fast-checks Linux route, run 45077068698, tested 677669cac88f (snapshot 12bef3cf838f), 8 CPU, 2486 s, n=5 per cell, seed 0.
Duress: shaped link profiles (cmux-fault Shaper, link-profiles.json v1) and session history at 1x, 10x and 100x, on a shared Linux CI runner; the machine itself was otherwise idle (load 0.05 at start). No simulator: this is the daemon-side protocol path a phone client drives, not the iOS app's render time.

Percentiles are nearest-rank over the n runs. "cold" is the first attach; "warm" is attaching again to the running daemon. The harness emitted no separate `reconnect` phase in this run, so there is no reconnect row; that is a gap in the harness, not a zero. terminal good-wifi cold 1x has 4 runs, not 5 (one line missing from the log).

| surface | profile | phase | history | first content ms p50 / p95 | interactive ms p50 / p95 | n ok | failed |
|---|---|---|---|---|---|---|---|
| terminal | good-wifi | cold | 1x | 15 / 16 | 64 / 65 | 4 | 0 |
| terminal | good-wifi | cold | 10x | 15 / 18 | 61 / 68 | 5 | 0 |
| terminal | good-wifi | cold | 100x | 16 / 17 | 60 / 64 | 5 | 0 |
| terminal | good-wifi | warm | 1x | 6 / 6 | — | 5 | 0 |
| terminal | good-wifi | warm | 10x | 6 / 6 | — | 5 | 0 |
| terminal | good-wifi | warm | 100x | 5 / 6 | — | 5 | 0 |
| terminal | lte | cold | 1x | 229 / 230 | 302 / 304 | 5 | 0 |
| terminal | lte | cold | 10x | 230 / 231 | 303 / 304 | 5 | 0 |
| terminal | lte | cold | 100x | 224 / 225 | 297 / 299 | 5 | 0 |
| terminal | lte | warm | 1x | 75 / 76 | — | 5 | 0 |
| terminal | lte | warm | 10x | 74 / 75 | — | 5 | 0 |
| terminal | lte | warm | 100x | 75 / 75 | — | 5 | 0 |
| terminal | lossy-3 | cold | 1x | 1040 / 1102 | 1428 / 1512 | 5 | 0 |
| terminal | lossy-3 | cold | 10x | 1040 / 1101 | 1429 / 1511 | 5 | 0 |
| terminal | lossy-3 | cold | 100x | 1041 / 1101 | 1428 / 1511 | 5 | 0 |
| terminal | lossy-3 | warm | 1x | 449 / 528 | — | 5 | 0 |
| terminal | lossy-3 | warm | 10x | 449 / 526 | — | 5 | 0 |
| terminal | lossy-3 | warm | 100x | 449 / 526 | — | 5 | 0 |
| terminal | lossy-10 | cold | 1x | 5630 / 7861 | 9093 / 13066 | 5 | 0 |
| terminal | lossy-10 | cold | 10x | 5584 / 7859 | 9091 / 13063 | 5 | 0 |
| terminal | lossy-10 | cold | 100x | 5584 / 7861 | 9079 / 13063 | 5 | 0 |
| terminal | lossy-10 | warm | 1x | 1349 / 3457 | — | 5 | 0 |
| terminal | lossy-10 | warm | 10x | 1389 / 3456 | — | 5 | 0 |
| terminal | lossy-10 | warm | 100x | 1391 / 3469 | — | 5 | 0 |
| terminal | lan | cold | 1x | 18 / 19 | 66 / 67 | 5 | 0 |
| terminal | lan | cold | 10x | 19 / 19 | 66 / 66 | 5 | 0 |
| terminal | lan | cold | 100x | 19 / 19 | 66 / 66 | 5 | 0 |
| terminal | lan | warm | 1x | 6 / 6 | — | 5 | 0 |
| terminal | lan | warm | 10x | 6 / 6 | — | 5 | 0 |
| terminal | lan | warm | 100x | 6 / 6 | — | 5 | 0 |
| terminal | internet-down-lan-up | cold | 1x | 19 / 19 | 66 / 66 | 5 | 0 |
| terminal | internet-down-lan-up | cold | 10x | 19 / 19 | 66 / 66 | 5 | 0 |
| terminal | internet-down-lan-up | cold | 100x | 19 / 19 | 66 / 66 | 5 | 0 |
| terminal | internet-down-lan-up | warm | 1x | 6 / 6 | — | 5 | 0 |
| terminal | internet-down-lan-up | warm | 10x | 6 / 6 | — | 5 | 0 |
| terminal | internet-down-lan-up | warm | 100x | 6 / 6 | — | 5 | 0 |
| chat | good-wifi | cold | 1x | 38 / 40 | 45 / 46 | 5 | 0 |
| chat | good-wifi | cold | 10x | 47 / 49 | 53 / 57 | 5 | 0 |
| chat | good-wifi | cold | 100x | 59 / 61 | 67 / 73 | 5 | 0 |
| chat | good-wifi | warm | 1x | 25 / 26 | — | 5 | 0 |
| chat | good-wifi | warm | 10x | 34 / 35 | — | 5 | 0 |
| chat | good-wifi | warm | 100x | 46 / 46 | — | 5 | 0 |
| chat | lte | cold | 1x | 366 / 368 | 441 / 444 | 5 | 0 |
| chat | lte | cold | 10x | 390 / 586 | 467 / 663 | 5 | 0 |
| chat | lte | cold | 100x | 426 / 614 | 507 / 691 | 5 | 0 |
| chat | lte | warm | 1x | 146 / 333 | — | 5 | 0 |
| chat | lte | warm | 10x | 312 / 324 | — | 5 | 0 |
| chat | lte | warm | 100x | 312 / 396 | — | 5 | 0 |
| chat | lossy-3 | cold | 1x | 1659 / 1695 | 2037 / 2201 | 5 | 0 |
| chat | lossy-3 | cold | 10x | 1658 / 1714 | 1980 / 2508 | 5 | 0 |
| chat | lossy-3 | cold | 100x | 1672 / 1732 | 1954 / 2317 | 5 | 0 |
| chat | lossy-3 | warm | 1x | 683 / 836 | — | 5 | 0 |
| chat | lossy-3 | warm | 10x | 688 / 885 | — | 5 | 0 |
| chat | lossy-3 | warm | 100x | 842 / 878 | — | 5 | 0 |
| chat | lossy-10 | cold | 1x | 7908 / 15166 | 9414 / 18623 | 5 | 0 |
| chat | lossy-10 | cold | 10x | 8140 / 15169 | 11166 / 16761 | 5 | 0 |
| chat | lossy-10 | cold | 100x | 8582 / 15169 | 11865 / 16586 | 5 | 0 |
| chat | lossy-10 | warm | 1x | 7541 / 15837 | — | 5 | 0 |
| chat | lossy-10 | warm | 10x | 7907 / 14408 | — | 5 | 0 |
| chat | lossy-10 | warm | 100x | 14062 / 15946 | — | 5 | 0 |
| chat | lan | cold | 1x | 30 / 31 | 39 / 40 | 5 | 0 |
| chat | lan | cold | 10x | 30 / 31 | 40 / 41 | 5 | 0 |
| chat | lan | cold | 100x | 33 / 35 | 44 / 50 | 5 | 0 |
| chat | lan | warm | 1x | 12 / 12 | — | 5 | 0 |
| chat | lan | warm | 10x | 13 / 14 | — | 5 | 0 |
| chat | lan | warm | 100x | 16 / 16 | — | 5 | 0 |
| chat | internet-down-lan-up | cold | 1x | 30 / 30 | 39 / 39 | 5 | 0 |
| chat | internet-down-lan-up | cold | 10x | 30 / 31 | 40 / 40 | 5 | 0 |
| chat | internet-down-lan-up | cold | 100x | 34 / 35 | 45 / 50 | 5 | 0 |
| chat | internet-down-lan-up | warm | 1x | 12 / 12 | — | 5 | 0 |
| chat | internet-down-lan-up | warm | 10x | 13 / 14 | — | 5 | 0 |
| chat | internet-down-lan-up | warm | 100x | 15 / 22 | — | 5 | 0 |

