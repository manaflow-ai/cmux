# Sidebar performance receipts

The sidebar has three fleet-only performance harnesses:

- `scripts/cmux-next/sidebar-rows-perf-live.py` measures ticking rows, scroll frames, hitches, and `debug.sidebar_perf` counters.
- `scripts/cmux-next/sidebar-rows-perf-release.py` measures Release scroll hitches and frame pacing against a plain AppKit floor.
- `scripts/cmux-next/sidebar-mirror-rebuild-perf.py` measures typed mirror calls during structural rebuilds.

Run those on an enrolled GUI host and write their JSON artifacts to one directory. Then validate the receipts from any portable runner:

```sh
python3 scripts/cmux-next/sidebar-perf-validate.py "$NX_ARTIFACTS/sidebar" \
  --require-counters \
  --max-frame-p99-ms 16.7 \
  --max-hitch-total-ms 250
```

The default structural budgets are zero rebuilds and zero list reloads during the measured counter phases, with row configures no greater than row patches. The validator also rejects harness-reported failures and requires mirror receipts to report successful view calls and rebuilds. Frame and hitch limits are explicit arguments because the absolute floor depends on the enrolled display and host; a workflow can tighten them after collecting base/candidate data on the same host.

This validator is intentionally separate from the GUI runner. The runner owns app launch, input, and trace capture; the portable validator owns deterministic receipt policy. A future fleet workflow can upload both base and candidate receipts and invoke this script before publishing the comparison.
