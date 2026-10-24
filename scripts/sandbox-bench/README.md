# Sandbox benchmark harness

This prototype measures the same command across a host-process baseline and
rootless gVisor. It records host capability gates for Firecracker and Cloud
Hypervisor instead of silently substituting a weaker isolation mode. The
output is JSON with p50/p95/p99 cold-start latency, failures, child RSS, and
concurrent density. Snapshot/restore/fork are explicit lifecycle states; a
`not_run` or `blocked` value is not a measurement.

The gVisor path is intentionally constrained to `runsc --rootless
--platform=systrap --network=none`. This is useful for an unprivileged lane
worker and prevents a benchmark command from inheriting host networking. A
production acpmux backend needs a separately provisioned network namespace and
an OCI create path before using checkpoint/restore.

## Run

```sh
python3 scripts/sandbox-bench/sandbox_bench.py probe \
  --runsc "$HOME/.local/bin/runsc"

python3 scripts/sandbox-bench/sandbox_bench.py cold \
  --backend process --iterations 30 -- /bin/true

python3 scripts/sandbox-bench/sandbox_bench.py cold \
  --backend gvisor --runsc "$HOME/.local/bin/runsc" \
  --iterations 30 -- /bin/true

python3 scripts/sandbox-bench/sandbox_bench.py density \
  --backend gvisor --runsc "$HOME/.local/bin/runsc" \
  --sizes 1,4,8,16 --hold-s 1 --host-cost-per-hour 0.80 -- /bin/true
```

Use `--json` for machine-readable results. The command after `--` is passed as
an argv vector; it is never evaluated by a shell. Keep benchmark commands
short and deterministic, and repeat them on the same host image when
comparing backends. `--host-cost-per-hour` is optional and only divides that
input by each measured concurrent size; it does not estimate utilization or
idle waste for you.

## VM adapter boundary

Firecracker and Cloud Hypervisor require `/dev/kvm`, a guest kernel, a rootfs,
and a network/vsock policy. This harness reports those prerequisites and
returns a non-zero status when they are absent. On a nested-virt or bare-metal
worker, the next adapter should use the same guest kernel/rootfs and expose
these timestamps:

```text
config_loaded -> vm_started -> guest_ready -> snapshot_created
             -> snapshot_restored -> fork_ready
```

Do not compare a Firecracker boot number with a gVisor `runsc do` number until
the guest command, image, CPU count, memory size, and readiness probe are the
same. Firecracker's snapshot API and gVisor's checkpoint/restore also have
different persistence semantics, so report them as separate rows.

## Evidence and limits

- Firecracker design notes describe sub-125 ms boot and snapshot support, but
  those are project claims; this harness is intended to replace them with
  p50/p95 numbers from our image and guest-ready probe.
- gVisor's performance guide recommends measuring host available memory before
  and after many instances; the density command reports aggregate peak RSS as
  a first local approximation. A fleet run should add host available-memory
  deltas and cgroup accounting.
- Vendor prices and marketing claims belong in the private business issue, not
  in this public helper. Pass a host hourly price and measured density there to
  compute `host_cost_per_sandbox_hour = host_cost_per_hour / density`.
