# Connections generalized tooling and goals

Leo's ask is: “Can you guys add better generalized tooling and goals and being able to test and bench and write stuff down for eg connections”.

## Scope

The connection lifecycle already had separate product and simulator seams.
`agent-chat/src/connection.ts` retries socket creation, errors, closes, and
response timeouts, but did not expose attempt timing or recovery outcomes.
`services/conversation-sim/pressure.ts` could reconnect and resume events, but
its client loop was unbounded and only printed a sent count. This change adds
one bounded benchmark over the real simulator WebSocket protocol.

## Generalized goal contract

Every run writes one `cmux.connection-bench.v1` JSONL record containing the
exact requested and observed drop counts, reconnect latency samples and
percentiles, lagged reconnects, replayed events, duplicate events, and the
idempotent-send result. A run passes when every requested drop is observed,
reconnect p95 is at most 3,000 ms, no reconnect is lagged, and retrying a
`clientMessageId` returns the same message id.

The contract is independent of the UI. A client adapter can use the same
simulator and compare its own recovery receipt against this record.

## Deterministic commands

Offline protocol and simulator coverage, with no agent or UI process:

```sh
bun run services/conversation-sim/selftest.ts
bun run services/conversation-sim/connection-bench.test.ts
```

Bounded connection duress against a process-owned simulator:

```sh
bun run services/conversation-sim/connection-bench.ts \
  --drops 5 --latency-scale 3 --fail-rate 0.2 \
  --history-fail-rate 0.1 --duplicate-rate 0 \
  --output artifacts/connection-bench.jsonl
```

The benchmark owns and terminates only the server process it starts. A live
client run uses the same command against a tagged build's simulator URL after
the adapter is wired to `SIM_URL`; that receipt belongs in the network baseline
with the build, host, and exact commit.

## Coverage and gaps

Automated tests cover percentile calculation, all three pass/fail goals, the
simulator protocol, forced disconnects, replay cursors, and idempotent sends.
The benchmark does not claim iOS foreground/background behavior or Wi-Fi path
change detection. Those remain covered by `docs/ios-network-reliability.md`
and require a fleet-device receipt.

## Measured receipt

Run: pending the first exact-head benchmark after the implementation test pass.
Duress: local process-owned simulator, five forced drops, latency scale 3,
send failure rate 0.2, history failure rate 0.1, duplicate delivery disabled.
The result is incomplete until the JSONL line is copied here with its exact
head and host.
