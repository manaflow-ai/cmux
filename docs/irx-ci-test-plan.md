# irx transport: CI test plan (release-lane gates)

Standing directive: transport guarantees gate RELEASES, not just PRs. Every
scenario below needs an automated test (unit, live-QUIC in-package, gated
live-relay, or scripted soak) before irx ships as the default in a release
channel. Field-found items name the incident that motivated them.

## Credentials and identity

1. Identity change with a stale credential cache (FIELD 08-26: identity
   adoption changed the endpoint key; cached relay tokens for the old key
   were silently refused; Mac hung at online() for 2h): cache bound to a
   different endpointIDHex must read as empty and trigger an immediate fresh
   mint. Cover account switch, sign-out/sign-in, key rotation, and the
   adoption transition itself.
2. Wrong-key token presented to a live relay never admits AND produces no
   client error (gated live test pinning the silent-refusal behavior our
   proactive check exists for).
3. online() deadline: a relay link that cannot come up fails the bind at 20s
   with an `online-timeout` journal event and enters the retry ladder
   (re-mint + rebind), never a silent hang.
4. Credential rotation is make-before-break: sessions survive >= 3
   consecutive 300s token boundaries with zero gap (soak criterion).
5. Mint failure retries at half remaining validity (accelerating), floor 1s;
   two consecutive failures self-heal without touching a live session
   (observed in soak round 1).
6. Steady-state independence: with cached credentials + grant and the broker
   UNREACHABLE, dial and admission still succeed.

## Admission and grants

7. Denials surface machine-readable codes via connection termination
   (invalid-grant, grant-expired, revoked, identity-mismatch) and are
   terminal for automatic retry (no denial storms).
8. A denied cached grant is dropped and re-minted on the next dial (FIELD:
   stale grant cache after slot changes).
9. Admission is offline: no broker call on the accept path; verification
   keys come from the persisted trust snapshot.
10. Supersession: a new connection from the same device replaces the old
    session; re-admission after app kill < 5s.
11. Identity adoption: binding refreshes in place (same endpointId +
    generation), existing pair grants stay valid, zero re-pairing.

## Reconnect discipline

12. Single reconnect owner: concurrent triggers coalesce into one dial
    (dial-joined), never parallel dials.
13. Sequential-dial cooldown (FIELD 08-25: app-layer retry loop produced 5
    dials in 200ms): automatic callers fail fast during backoff; explicit
    intent overrides.
14. Kill recovery: host killed mid-session -> client re-admitted <= 3s from
    its own journal timestamps (fault-injection harness).
15. Keepalive: silent path blackhole detected within interval + deadline
    (5s + 2s); every pong carries path attribution; force-relay soak shows
    100% relay-attributed samples.
16. Provisioning atomicity (FIELD 08-25: transient auth failure during
    launch sign-in poisoned a half-built broker; every later call 403'd):
    partial provisioning must never publish; single-flight; retry converges.

## Routing and hints

17. Relay hint resolution: tickets strip hints (FIELD 08-25: wrong-relay
    dial black-holed 30s), so the dialer resolves the target's registered
    home relay from discovery; missing hint falls back to own relay with a
    journaled warning.
18. Hint refresh: host re-registers its ACTUAL home relay; hint never lapses
    (FIELD 08-26: 30-min hint expired after the refresh only ran at
    activation); throttle writes only on URL change or half-window age
    (churn: every registry write fans invalidations account-wide and legacy
    stacks re-dial pooled sessions on each one).
19. Route-revision pushes never tear down healthy irx sessions.

## Compatibility (dual ALPN)

20. Old-protocol phone admits through the legacy dialect acceptor over the
    irx endpoint; terminal + RPC + events work.
21. A wedged/slow legacy session cannot stall an irx session (separate
    connections; QUIC flow control).
22. Per-ALPN kill switch: disabling the legacy listener refuses new legacy
    dials while irx sessions continue unaffected.
23. irx phone vs old Mac: dial is ALPN-refused fast and surfaces the
    update-your-Mac state (no 30s hangs); What's New compat notice renders
    with the exact version constants.

## App integration

24. Env-less relaunch stays in irx mode (sticky flags; FIELD 08-25: sim-leg
    reinstall relaunched without env, fell to legacy, sat Not Connected).
25. UITest loopback mock-host flows work in default mode; force-relay rigs
    register no fallback transports.
26. Events lane negotiation falls back to control-stream delivery when the
    uni lane is unavailable.
27. Terminal lane: cursor-gap rejection code, replay-first framing, input
    frame bounds.
28. 15-minute relay-only engaged soak as a release-lane gate (the full
    original acceptance criteria: establish <= 3s, zero unexplained session
    ends, zero non-relay samples, >= 3 rotations/side, engaged input,
    changing screens).

## Not yet covered / future

29. Direct-path upgrade (post-admission NAT traversal authorization + LAN
    hints) once wired: path migration without session drop.
30. Radio lifecycle on physical devices: lock/unlock, background/foreground,
    LTE<->WiFi handoff -> recovery <= 3s, every transition attributed.
31. Simulator-stream lanes over irx (currently unsupported).
32. PostHog kill-switch bridge: flag flip reverts to legacy stack on next
    launch without wiping state.
