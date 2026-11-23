# Linux VM autoscaling experiment

Default off. This isolated Rust experiment replays one advisory capacity pass from RFD 0012.
It is a CLI experiment under `experiments/`, not a Settings toggle or a deployed controller.
It never reads credentials, accesses the network, writes targets to hosts, or starts or stops VMs.
Existing runner routing and all deployed defaults stay unchanged.

On a Linux build runner:

```sh
rustc --edition=2021 experiments/linux-vm-autoscaling/capacity.rs -o /tmp/capacity
/tmp/capacity # disabled; reads no reports
/tmp/capacity --enabled --now 1000 --queued 7 < experiments/linux-vm-autoscaling/reports.tsv
```

Omit `--enabled` to turn it off. Targets go only to stdout. Do not install them on hosts.
Use a real UTC Unix timestamp for `--now` when evaluating captured reports.

Input is whitespace-separated, one host per line; `#` lines are comments. Fields are:
`host age_seconds class ceiling occupied cores cpu_percent ram_gib used_gib memory_budget_gib yielding`.
Class is `ultra` or `standard`; yielding is `yes` or `no`. Include every occupied reservation,
including starting and warm clones. Utilization includes their current resource use.
The memory budget must fit 90% of RAM minus the 8 GiB host reserve. Invalid reports fail the whole pass.
Reports are limited to 256 hosts and 256 KiB. Ceiling and occupied counts are each at most 64.

The caller supplies a deduplicated queued count. This deliberately does not guess whether listener
statistics overlap across scale sets; RFD 0012 leaves that as a measurement required before deployment.
Demand is queued plus occupied work. New slots go to the host with the most projected minimum CPU/RAM
headroom, ultras first on ties, then host name. Each slot projects 4 cores and 8 GiB; CPU and RAM must
remain strictly below 90%. Reports older than 30 seconds and yielding hosts get target zero. Occupied
work is printed separately and is never killed. When idle, eligible idle hosts get one warm target.
Targets expire after 60 seconds. Recomputing free targets on each pass returns spare capacity without
tracking previous advice. The algorithm is bounded by 256 * 64 candidate slots even with an enormous queue.

## Evidence and remaining integration

The supplied fixture is synthetic, not fleet telemetry. With 7 queued jobs the pass must advertise
7 new slots across the two serving hosts, and zero on the yielding and stale hosts. Unit tests cover
CPU/RAM pressure, ceilings, invalid and duplicate reports, expiry, disabled input, and running work.

RFD 0012 cites saved-state restore at **1.8 s versus 8.1 s** for a cold boot. Those are the design's
prior measurements, not a result of this experiment. This replay does not boot VMs. The design's jobs/hour
and queue-wait p50/p90 before/after measurements require the listener/host integration; none is claimed here.

Production report transport, persistent controller state, host admission capping, warm runner lifecycle,
and saved-state restore remain owned by the design's glaeda/HQ sequence. This replay is not wired into
those services. To verify on the fleet without adding any CI job:

```sh
cmux-ci test --setup rust --timeout 600 -- 'set -eu
out=$(mktemp -d)
rustc --edition=2021 --test experiments/linux-vm-autoscaling/capacity.rs -o "$out/tests"
"$out/tests"
rustc --edition=2021 -D warnings experiments/linux-vm-autoscaling/capacity.rs -o "$out/capacity"
"$out/capacity"
"$out/capacity" --enabled --now 1000 --queued 7 < experiments/linux-vm-autoscaling/reports.tsv'
```
