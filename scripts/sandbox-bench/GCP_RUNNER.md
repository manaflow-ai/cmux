# Disposable nested-virt GCP runner

`gcp_nested_runner.py` provisions one `n4d-standard-16` instance in the
project supplied by `--project` (or `CMUX_GCP_PROJECT`) and runs the sandbox
capability probe on it. It is a dry run unless `--apply` is passed. The default
run prints the exact `gcloud` commands without making a cloud API call (it
still requires `gcloud` to be installed).

```sh
# Review the plan; no instance is created. Values can also come from
# CMUX_GCP_PROJECT, CMUX_RESOURCE_OWNER, and CMUX_RESOURCE_PURPOSE.
python3 scripts/sandbox-bench/gcp_nested_runner.py --json \
  --project example-project --owner example-owner --purpose example-purpose

# Explicitly create, probe, and delete one instance.
python3 scripts/sandbox-bench/gcp_nested_runner.py --apply --json \
  --project example-project --owner example-owner --purpose example-purpose
```

The instance name is random and the create request carries the caller's owner
and purpose labels plus a TTL label:

```text
owner=<caller supplied>
purpose=<caller supplied>
ttl-hours=4
```

The startup script writes a readiness marker and runs a watchdog. It powers
the VM off at the hard TTL or after the idle marker has not been touched for
the configured idle interval (15 minutes by default). The runner touches that
marker before its probe. On normal completion or any failure after a successful
create, it deletes only that exact generated name. `--keep` is an explicit
escape hatch for debugging; the watchdog remains active.

Before marking the VM ready, startup installs pinned x86_64 releases of
gVisor `runsc` `release-20261019.0`, Firecracker `v1.17.0`, and Cloud
Hypervisor `v54.0` under `/opt/rd-sandbox/bin`. The gVisor and Firecracker
archives are SHA-256 checked before extraction. The probe passes those paths
explicitly, so a successful run tests the selected binaries rather than an
ambient PATH. Guest kernel/rootfs images are intentionally caller supplied for
the next Firecracker boot slice; installing an image here would make the
benchmark less reproducible.

The runner does not create firewall rules, networks, routes, IAM bindings,
service accounts, disks, or snapshots. It uses an ephemeral external IP on the
existing `default` network, so SSH requires the existing network policy to
permit it. If a create command fails after the API accepted it, cleanup is
allowed only when a follow-up describe confirms the caller's owner and purpose
labels on the generated name. An unrelated instance is never deleted.

## Permissions and limits

The invoking principal needs, at minimum, `compute.instances.create`,
`compute.instances.get`, `compute.instances.setMetadata`, and
`compute.instances.delete` on the project. The create call also needs
`compute.subnetworks.use` and `compute.subnetworks.useExternalIp` for the
existing default network, plus `compute.zones.get`/`compute.projects.get` for
normal gcloud discovery. `iam.serviceAccounts.actAs` is needed if the project
attaches a service account. SSH via OS Login needs the appropriate
`roles/compute.osLogin` (or admin variant), and `gcloud compute ssh/scp` needs
the normal SSH key propagation permissions.

The runner intentionally does not request broad project IAM or firewall
permissions. A `PERMISSION_DENIED`, missing zone/machine type, unavailable
external IP, or failed SSH leaves the error in the receipt and triggers the
exact-name cleanup path when possible. No secret or access token is written to
the receipt or metadata.

N4D availability is regional. Choose `--zone` from a zone that offers the
requested N4D shape; the default `us-west1-a` is a starting point, not a
guarantee. The guest probe is the checked-in `sandbox_bench.py`; pass a pinned
copy with `--probe-file` for a fleet run.
