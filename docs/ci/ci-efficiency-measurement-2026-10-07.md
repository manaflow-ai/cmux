# CI efficiency measurement receipt

Captured 2026-10-08T05:20Z from local `cmux-ci status`, fleet runner status,
and the controller's worker and storage receipts. The status export contains
1,190 jobs; this readout uses 387 `cmux` jobs with a named worker. No GitHub
API or retired ci-dash utilization data was used.

The current receipt inventory is 424 `cmux`, 719 `ci-step`, 33 `ios`, 7
`cef`, and 7 `cmux-browser` rows. The `cmux` state counts are 269 done, 94
failed, 58 cancelled, and 3 running. The phase measurements below use
controller timestamps and phase receipts. AWS means the AWS pool; mini means
the named local Mac mini workers. Percentiles are inclusive p50 and p90 in
seconds.

| segment | AWS n / p50 / p90 | mini n / p50 / p90 | meaning |
| --- | ---: | ---: | --- |
| controller queue | 120 / 284 / 962 | 267 / 34 / 1,602 | `created_at` to `started_at` |
| controller admission phase | 120 / 0 / 0 | 264 / 0 / 0 | controller decision only; not host setup |
| `cmux_build` compile | 114 / 144 / 182 | 239 / 379 / 924 | compile phase duration |
| artifact upload | 84 / 8.5 / 11.9 | 185 / 5.4 / 8.4 | upload phase duration |
| storage cleanup snapshot | 120 / 0.018 / 0.028 | 264 / 0.162 / 1.686 | `after_cleanup` minus `before_cleanup` |

The recovered host JSONL read adds this setup and run split. These are
historical host receipt subsets, not rows in the current controller export;
the raw host files are not mounted in this checkout.

| host receipt subset | started / completed | admission wait p50 / p90 / max (s) | host run p50 / p90 (s) | telemetry and contention |
| --- | ---: | ---: | ---: | --- |
| AWS relay 7 | 159 / 159 | 13.5 / 365.4 / 978.3 | 205.2 / 218.2 | 58 contended, 95 refused, no compile telemetry |
| AWS relay 8 | 86 / 85 | 0.8 / 3.4 / 1,077.5 | 646.2 / 1,014.5 | compile telemetry 22 rows, 16 contended |
| AWS relay 9 | 89 / 88 | 0.8 / 3.7 / 297.3 | 322.2 / 835.3 | compile telemetry 26 rows, 19 contended |
| local mini control | 3,287 / 3,283 | 0.9 / 167 / 1,037 | 344.3 / 716.3 | compile telemetry 752 rows, 280 contended |

For the telemetry subsets, nested compile fetch was 35.6/61.8 seconds on
relay 8, 91.8/97.4 on relay 9, and 54.9/102.7 on the mini control. The
corresponding disk-throughput p50/p90 was 52.8/69.4 MB/s and 57.8/131.5 MB/s
on relays 8 and 9. The isolated mini subset had admission 0.8/4.7 seconds and
run 255.8/647.3 seconds, with 710 of 1,188 rows contended. Host run is
started-to-completed and is not a substitute for the controller's compile
phase.
No recovered host row carried paired eviction start and finish timestamps, so
cleanup and eviction remain unproven beyond the controller cleanup snapshot.

The controller has no host-side runner-ready or admission-wait breakdown. The
zero admission phase is therefore not evidence that setup is free. The current
export also has no rows for the affected AWS relay hosts, so their setup stalls
must be joined from the host job JSONL receipts. Those receipts already carry
`wait_s`, blocked processes, disk throughput, verdict, and contention reason.

Earlier transport receipts remain consistent with keeping aggregate transport:
aggregate restores were about 34 to 90 seconds, versus 68 to 231 seconds for
layered restores. R2 endpoint timing was about 130 to 150 ms. Neither result
proves R2 is the bottleneck, and this receipt does not change routing or cache
policy.

## Smallest missing receipt

Add `runner_ready_at` to the existing host job receipt, keyed by the controller
job ID, and retain the existing wait reason. The controller already supplies
`created_at` and `started_at`, while the workflow readout now supplies the
first workflow step and final workflow step boundaries. This one host timestamp
will separate controller queue from host admission and runner setup without
changing placement or artifact transport.

## AWS relay canary

Run 20 unchanged cmux builds during ordinary load through the AWS relay lane,
retaining the controller receipt and the matching host JSONL row for every
job. Include eligible relay rows and one local-mini control without forcing
placement; leave any host without an eligibility receipt out until it is
repaired. Split the rows by relay host and local mini, then calculate:

1. `created_at` to `started_at` (controller queue).
2. `started_at` to `runner_ready_at` (host admission and setup).
3. `runner_ready_at` to the first host recipe phase (runner handoff).
4. First host recipe phase to `cmux_build` completion (compile).
5. Cleanup start to cleanup finish, with the existing blocked-process and
   contention fields (cleanup and eviction).

Treat a setup stall as proven only when the joined receipt contains the long
interval and its wait reason. Do not kill processes, clear broad caches, or
override routing for this canary.

Implementation on this branch is limited to the GitHub timing readout in
`scripts/ci/ci_timing_readout.py`: it excludes `Set up job` and `Complete job`
bookends, and reports runner setup and cleanup columns when workflow steps are
present. Missing workflow steps render as unknown rather than zero.

Source snapshot hashes:

```text
status  c9a2f5a1b8826626fc9b399eb90b0f181600a3dc8d42f39c1fce1748954d9fbd
workers 83caf9ccfb6446dcabe6960d5c6d128057543da5202ce34266034ee610c6aac9
storage 0a01fe9a8f0986358bfce5781a03ad4960f102d35ec4c03e034fe4eb33ba7fda
```
