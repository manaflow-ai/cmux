# CI compute pool audit experiment

Default off. This read-only Rust experiment implements the owned-member detector
from [CI compute, build-order item 6](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/rfd/0012-ci-compute.md).
It reads the actual `.github/runners.json`; it does not change routing, provision
machines, register runners, or add a CI gate. This is a CLI experiment under
`experiments/`, with no app setting or UI change.

From the repository root on a Linux build worker:

```sh
# Disabled: prints enabled=false without opening either input file.
cargo run --locked --manifest-path experiments/ci-compute/Cargo.toml --
# Explicitly opt in for this invocation only.
cargo run --locked --manifest-path experiments/ci-compute/Cargo.toml -- --enable
```

Exit 0 means disabled or an audit without actionable findings; 2 means findings;
1 means invalid arguments, missing input or malformed configuration. Output is
JSON with each pool's members, configured owned Linux members, unknown labels,
status and any declared hosted-only reason. `--runners PATH --labels PATH` accepts
other snapshots. Omit `--enable` to turn it off; no state persists.

The checked-in `labels.json` is a reviewed inventory for this experiment, not a
runner registration or routing source. Ownership is explicit, never inferred
from a label prefix. A new label requires an inventory entry; until then its
pool reports `unknown-label`, even if another member is owned. Linux pool names
and known Linux members identify Linux pools, including `promotion`. All pools
are inspected, so unknown labels in a renamed pool remain findings. An owned
Mac cannot satisfy a Linux pool. An explicit hosted constraint with a reason is
reported as `hosted-required`, never as independent capacity.

On the initial repository snapshot, nine Linux pools are classified: seven have
a configured owned member, `linux_arm64` reports `missing-owned`, and `provenance`
reports its existing hosted requirement. A configured member is **not proof of
online capacity**. The inventory and real-file integration test must be reviewed
when routing changes; the experiment is not wired into normal CI.

## Verify

```sh
cmux-ci test --setup rust --timeout 600 -- \
  'cargo test --locked --manifest-path experiments/ci-compute/Cargo.toml'
```

Tests exercise the binary against the real pool file, the disabled path with
missing files, same-provider size fallbacks, unknown labels, malformed input,
mixed platforms, and declared hosted requirements. All policy logic is Rust.

This slice detects a capacity dependency; it does not improve queue time. The
design's historical queue p95 changed from 6 seconds to 6,936 seconds during
starvation; its recovery target is below 60 seconds. No after measurement is
claimed. Scaler self-dependency and per-label queue goals remain follow-up work.
