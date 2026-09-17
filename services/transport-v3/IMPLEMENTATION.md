# V3 implementation status

Goal: completely replace the iOS transport and iroh, with Rust client/server,
Stack identity, team ACLs, configurable finite/infinite offline access, native
P2P with relay fallback, future browser support, Azure multi-region deployment,
seamless upgrades, observability, security audit, and real end-to-end proof.

## Accepted design

- Stack remains the login and team identity provider. Device keys identify peers.
- Cedar decisions run server-side. Receiving endpoints enforce signed grants.
- Timing is administrator controlled; selected users/devices may use explicit
  unlimited offline access. Infinite permission has no offline revocation bound.
- Regional relays have explicit addresses and backup reservations. A global API
  discovers them; no anycast session routing or inter-relay mesh initially.
- No legacy compatibility. Application sessions must survive transport reconnects.
- Existing cmux database is PlanetScale Postgres. No database migration or new
  database provider has been selected/deployed for v3 yet.

## Evidence and corrections

- Foundation commit 6c4c577fa3e: 15 Rust tests, Chromium relay interoperability,
  device/simulator target checks, Linux and Apple CI pass. No real NAT evidence.
- Initial production relay draft is incomplete: only transport identity was
  checked, not team relay admission. It must not be deployed in that state.
- Stock libp2p-relay 0.21.1 has no source/destination admission callback. Add a
  minimal hook in manaflow-ai/rust-libp2p, preserving the standard wire protocol.
- Closing listeners and restarting after a fixed delay does not prove seamless
  upgrade. Drain must reject new circuits on existing connections too, retain
  established circuits, and require client session handover before termination.
- Metrics in the first draft double-count renewals and can underflow on closure;
  replace arithmetic estimates with event-owned sets. Protect management access.
- Fork hook implemented at e277dfbd12a6491e1c09befa3651191ab7965893 in
  https://github.com/manaflow-ai/rust-libp2p/pull/1 (author lawrencecchen).
  All 9 relay integration tests pass. Live counts now come directly from relay
  behavior ownership, including pending circuits, rather than duplicate counters.
- Relay now requires public authority keys and private on-disk identity/management
  credentials; cached grants are bound to authenticated source, destination, team
  and action. Missing grants and cross-team circuits are denied by the relay hook.
- Actual server-process test passes: forged grant denied, valid reservation/pair
  accepted, unauthorized drain denied, readiness false during drain, established
  circuit still exchanges application data, clean exit after circuit closes.
- Local `ops/azure/*.sh` files are UNTESTED superseded drafts, not deployed. They
  still assume the old environment-based keys and timed restart. Replace with
  generation-based provisioning, private management, mounted secrets, public TLS,
  managed registry identity, and drain-to-zero before any invocation or commit.
- The supervisor must use restart-on-failure, not restart-always/unless-stopped:
  a clean exit after drain must stay stopped instead of resurrecting the old relay.
- Current workspace verification: 20 Rust tests and strict Clippy pass, including
  the new actual-server process test. Hosted checks on the updated commit and
  real Azure/NAT/iPhone testing remain outstanding.

## Work remaining

- [ ] Authenticated Rust control service, trusted device enrollment and team membership.
- [ ] Persistent state, policy mutation, regional freshness and revocation delivery.
- [ ] Destination-aware relay admission, quotas, draining, TLS and stable identity.
- [ ] Session streams, authorization renewal/expiry, replay, input acknowledgments.
- [ ] Swift bindings and complete iOS/macOS v3 integration; remove iroh path.
- [ ] Azure deployment through CLI, public endpoint and authenticated live E2E.
- [ ] Healthy overlapping generations, canary rollout, safe rollback and draining proof.
- [ ] Collected metrics/logs, alerts, probes, operating/recovery runbook.
- [ ] NAT/blocked-UDP/network-change/suspension/cross-region/revocation E2E matrix.
- [ ] Security audit of code and deployed configuration; address findings.
- [ ] Final requirement-by-requirement evidence audit.

## Dependency audit checkpoint

- Added the dependency-audit gate in separate failing commit 2dbb3cef290.
- cargo-audit 0.22.2 found RUSTSEC-2026-0118 and RUSTSEC-2026-0119 in
  Hickory 0.25.2. Fork commit 5e889629590ae4b52a0213a2ab85a28cb1ffeb3b
  upgrades Hickory to 0.26.3 and adapts DNS and mDNS APIs. DNS configuration
  construction now returns errors instead of introducing a new panic.
- After updating the application pin: 20 Rust tests pass, strict Clippy passes,
  dependency audit reports zero vulnerabilities. One maintenance warning remains
  for paste (not in the selected runtime dependency tree).
- Fork DNS tests (2), DNS builder tests (3), and mDNS unit tests (5) pass.
  The mDNS IPv6 integration test fails on this fleet host with unavailable
  interface addresses, identically on the pre-update baseline. V3 does not enable
  mDNS; this is not evidence of working IPv6 transport and must not be hidden.
- The audit is only a dependency checkpoint. Application threat-model review,
  deployment configuration audit, and all final-state E2E requirements remain.
