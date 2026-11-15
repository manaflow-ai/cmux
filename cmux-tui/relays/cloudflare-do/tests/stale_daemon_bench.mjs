// Times a client's Connect -> circuit Ready against a real relay Worker
// (`wrangler dev`) while the slot still holds a daemon registration that
// will never join a circuit, the way a fresh Cloud machine's slot holds the
// registration from its previous boot.
//
// Each trial uses its own slot:
//   1. a "previous boot" daemon registers, then goes silent with its socket
//      left open (it reads nothing and never pings again);
//   2. after STALE_AGE_MS the client sends Connect (accepts_parked);
//   3. FRESH_DELAY_MS later the fresh daemon registers and joins every
//      Incoming it gets.
// The client behaves like cmux's: on Allocated it joins the circuit and
// waits up to JOIN_TIMEOUT_MS (control_timeout) for Ready; if none comes it
// backs off BACKOFF_MS and sends Connect again.
//
// Usage: node tests/stale_daemon_bench.mjs URL KEY [TRIALS] [STALE_AGE_MS]
// Prints one JSON line per trial and a summary line.

import { randomBytes } from "node:crypto";

import { PROTOCOL, relay, send, sleep } from "./relay_harness.mjs";

const [, , baseUrl, key, trialsArg = "10", staleAgeArg = "20000"] = process.argv;
if (!baseUrl || !key) {
  console.error("usage: node tests/stale_daemon_bench.mjs URL KEY [TRIALS] [STALE_AGE_MS]");
  process.exit(2);
}
const TRIALS = Number(trialsArg);
const STALE_AGE_MS = Number(staleAgeArg);
const FRESH_DELAY_MS = 1_000;
const JOIN_TIMEOUT_MS = 15_000;
const BACKOFF_MS = 1_000;
const GIVE_UP_MS = 60_000;

const { ticket, open, next, register, join: joinCircuit } = relay(baseUrl, key);
const join = (slot, role, incoming) => joinCircuit(slot, role, incoming, JOIN_TIMEOUT_MS);

async function freshDaemon(slot, sockets) {
  const control = await register(slot, (socket, message) => {
    if (message.type === "incoming") {
      join(slot, "daemon", message).then(({ socket: circuit }) => sockets.push(circuit), () => {});
    } else if (message.type === "ping") {
      send(socket, { type: "pong", nonce: message.nonce });
    }
  });
  sockets.push(control);
}

async function trial(index, stale) {
  const slot = stale.slot;
  const sockets = [stale.socket];
  const lane = `lane-${index}`;
  const generation = 1;
  const started = Date.now();
  setTimeout(() => freshDaemon(slot, sockets).catch(() => {}), FRESH_DELAY_MS);
  let attempts = 0;
  let parked = false;
  try {
    while (Date.now() - started < GIVE_UP_MS) {
      attempts += 1;
      const bearer = ticket("connect", "client", slot, { lane, generation });
      const control = await open(`/v1/slots/${slot}/connect`, bearer);
      sockets.push(control);
      const answer = next(
        control,
        (m) => {
          if (m.type === "parked") parked = true;
          return m.type === "allocated" || m.type === "error";
        },
        GIVE_UP_MS,
      );
      send(control, {
        type: "connect",
        protocol: PROTOCOL,
        slot,
        ticket: bearer,
        lane,
        generation,
        accepts_parked: true,
      });
      const allocated = await answer;
      if (allocated?.type === "allocated") {
        const { socket, ready } = await join(slot, "client", allocated);
        sockets.push(socket);
        if ((await ready)?.type === "ready") {
          return { trial: index, ms: Date.now() - started, attempts, parked };
        }
      }
      control.close();
      await sleep(BACKOFF_MS);
    }
    return { trial: index, ms: null, attempts, parked };
  } finally {
    for (const socket of sockets) socket.terminate();
  }
}

const stale = await Promise.all(
  Array.from({ length: TRIALS }, async (_, index) => {
    const slot = `bench-${randomBytes(6).toString("hex")}-${index}`;
    const socket = await register(slot);
    // The previous boot is gone: nothing reads this socket or pings on it.
    socket.pause();
    return { slot, socket };
  }),
);
await sleep(STALE_AGE_MS);
const results = await Promise.all(stale.map((entry, index) => trial(index, entry)));
for (const result of results) console.log(JSON.stringify(result));
const times = results.map((r) => r.ms ?? Infinity).sort((a, b) => a - b);
const pick = (q) => times[Math.min(times.length - 1, Math.floor(q * times.length))];
console.log(
  JSON.stringify({
    summary: true,
    trials: TRIALS,
    stale_age_ms: STALE_AGE_MS,
    p50_ms: pick(0.5),
    max_ms: times[times.length - 1],
    retried: results.filter((r) => r.attempts > 1).length,
    parked: results.filter((r) => r.parked).length,
  }),
);
process.exit(0);
