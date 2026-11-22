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

The table lands here when the run reports.
