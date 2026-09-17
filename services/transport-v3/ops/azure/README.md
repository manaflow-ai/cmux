# Azure relay operations

Status: first staging deployment in progress. This runbook describes intended
checks, not completed evidence. `IMPLEMENTATION.md` tracks missing integration.

## Provisioning and identities

`deploy.py` builds a committed revision in Azure Container Registry and pins
both relay and TLS proxy images by digest. Each generation gets new VM names,
DNS endpoints and independently generated device identity. It never stops or
replaces a node that has an installed receipt. The only distributed authority
material is the public verification key set. Signing seeds stay off relays.

Management HTTP and internal WebSocket listeners bind to loopback. Network
security groups expose TCP 80/443/4001 and UDP 4001, with no public SSH or
management port. The VM managed identity can pull images only. The relay runs
as UID 10001 with a read-only root, dropped capabilities, no new privileges,
and bounded memory, process and CPU resources. Cloud-init installs the runtime
before the operator invokes installation through Azure Run Command.

## Required release sequence

1. Build an immutable image from the reviewed commit; run the dependency audit,
   relay process tests, Stack/proof tests, PostgreSQL tests and browser test.
2. Provision the new generation alongside the old one. Verify private readiness,
   public TLS and all advertised transports. Use `live_relay` to reject a forged
   permission and transfer more than the upstream relay's default byte limit.
3. Publish the new addresses in the authoritative directory. Existing hosts must
   establish replacement reservations before removing old ones. Promote a canary
   first; hold promotion if auth denials, connection failures, queue growth,
   connection establishment time or input acknowledgment latency regress.
4. Clients move application sessions using replay cursors and acknowledged input.
   An existing circuit is not automatically migrated by libp2p.
5. Recheck replacement health live, then drain old nodes through their private
   management endpoint. A drained node refuses new circuits, including requests
   on existing connections. Established circuits keep working until they finish.
6. Retire an old VM only after its live circuit count is zero and all client
   handovers are acknowledged. A deadline is an escalation signal, not permission
   to force-kill sessions. Restart-on-failure keeps a cleanly drained node stopped.

Rollback republishes the previous healthy generation. Keep its keys and image
until the observation window ends. If a node already drained and exited, run a
new generation from the previous digest instead of reviving stale reservations.
No destructive cleanup is automated by these scripts.

## Observability contract

The relay emits private OpenMetrics at `/metrics`, health at `/healthz`, and
readiness at `/readyz`. `manage.py status` queries them using Azure Run Command.
Current gauges: active reservations, circuits (including pending negotiation),
transport connections, readiness and seconds spent draining. Counters: accepted
and denied permission requests, denied reservations, denied circuits. Metrics
must not contain bearer grants, private keys, terminal content or user labels.

Remaining before production: continuous central scraping/log collection,
transport bytes and latency histograms, per-team quotas, alert routing and an
end-to-end synthetic probe. Alert on missing heartbeat, no healthy generation,
permission-denial spikes, certificate expiry, sustained memory pressure and a
stalled drain. Readiness must never be inferred from VM provisioning alone.

## Evidence

Retain build run ID, source SHA, image digest, node PeerIds, authority key IDs,
DNS/TLS results, synthetic probe receipts and an upgrade recording/transcript.
A loopback test or successful image build does not prove a deployed relay works.
