# Persistent machine prototype

This experiment models a provider-neutral cmux machine that can be allocated,
attached through cmux/acpmux, metered, stopped after an idle window, and resumed
without changing its machine identity. `machine_runtime.py` is deterministic and
uses an in-memory provider for local tests. `machinectl.py` emits a reviewable GCP
Compute Engine command but never executes it.

```sh
python3 -m unittest discover -s experiments/rd-vercel-compute/tests -v
python3 experiments/rd-vercel-compute/machinectl.py demo

# GCP dry-run; set the project and required labels explicitly.
GOOGLE_CLOUD_PROJECT=example-project \
CMUX_MACHINE_OWNER=research-owner CMUX_MACHINE_PURPOSE=persistent-machine \
python3 experiments/rd-vercel-compute/machinectl.py allocate --dry-run
```

Every receipt includes a machine/provider identity, `cmux://` and `acpmux://`
attach addresses, expiry, `owner`, `purpose`, `ttl`, and `idle-autostop` labels,
plus compute and disk meter totals. The GCP command is an adapter seam, not a
claim that a VM was created; a production implementation should submit it through
the provider-neutral machine contract and reconcile the returned provider ID.

The first authorized invocation should use the project and owner/purpose labels
assigned by the operator, and should include a TTL. Delete the VM and disk after the experiment. No credentials are
accepted in the manifest, command, or receipt.
