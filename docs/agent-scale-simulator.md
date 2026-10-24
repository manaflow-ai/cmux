# Agent fan-out simulator

This prototype exercises the control-plane decisions for running many cmux agents across hosts and providers. It makes no cloud calls. The input is a list of normalized provider offers, so a GCP, AWS, or another adapter can be evaluated with the same scheduler rules.

Run it from the repository root:

```sh
python3 scripts/agent_scale_sim.py --demo
python3 -m unittest discover -s tests -p 'test_agent_scale_sim.py' -v
```

The demo emits an event stream and a summary with startup p50/p95, active-run peak, interruptions, terminal states, and accrued dollars. The event stream is the intended hand-off to an observability backend; each event has a timestamp, run id, provider/region/host, and fencing token where applicable.

The model has five boundaries:

1. `RunRequest` is durable intent. Its image digest, shape, lifetime, retry policy, and idempotency key are immutable.
2. `Offer` is the provider adapter contract. It normalizes provider, region, host, startup estimate, price, preemptible state, interruption risk, and capacity.
3. A warm slot is an already booted `(provider, region, image, shape)` member. Claims are serialized by a token and are released back to the pool after completion.
4. A `Lease` is the ownership fence. Heartbeats extend it; expiry or an old token cannot renew it after the lease is released or interrupted.
5. The event stream is the accounting source. Lease segments calculate cost per agent-hour, while run events provide startup and interruption metrics.

A real controller should persist the event sequence and desired `RunRequest` state, then reconcile provider state after a restart. Provider calls should use the run idempotency key. Snapshot/fork is represented by `snapshot()` and `fork()`: the child carries the immutable snapshot digest and is scheduled like any other request.

The simulator deliberately leaves image baking, VM API calls, and host pool resizing to the provider owner. For GCP, the adapter can map `Offer` to the existing image/snapshot and instance-group implementation; the scheduler only consumes the normalized result and enforces global and tenant quotas.
