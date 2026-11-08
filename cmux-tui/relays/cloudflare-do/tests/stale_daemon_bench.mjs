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

import { createHmac, randomBytes } from "node:crypto";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const WebSocket = require("ws");

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
const PROTOCOL = 5;
const ISSUER = "cmux-relay";

const b64 = (bytes) => Buffer.from(bytes).toString("base64url");

function ticket(permission, role, slot, extra = {}) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    version: 2,
    issuer: ISSUER,
    permission,
    role,
    slot,
    circuit: extra.circuit ?? null,
    lane: extra.lane ?? null,
    generation: extra.generation ?? null,
    issued_at_unix: now,
    expires_at_unix: now + 240,
  };
  const payload = [
    "cmux-relay-ticket-v2",
    claims.version,
    claims.issuer,
    permission,
    role,
    slot,
    claims.circuit ?? "",
    claims.lane ?? "",
    claims.generation ?? "",
    claims.issued_at_unix,
    claims.expires_at_unix,
  ].join("\n");
  const signature = createHmac("sha256", key).update(payload).digest();
  return `v2.${b64(JSON.stringify(claims))}.${b64(signature)}`;
}

function open(path, bearer) {
  const url = baseUrl.replace(/^http/, "ws") + path;
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers: { Authorization: `Bearer ${bearer}` } });
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
    socket.once("unexpected-response", (_, response) =>
      reject(new Error(`${path}: HTTP ${response.statusCode}`)),
    );
  });
}

const send = (socket, message) => socket.send(JSON.stringify(message));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function next(socket, accept, timeoutMs) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => done(null), timeoutMs);
    const onMessage = (data) => {
      const message = JSON.parse(data.toString());
      if (accept(message)) done(message);
    };
    const onClose = () => done(null);
    function done(value) {
      clearTimeout(timer);
      socket.off("message", onMessage);
      socket.off("close", onClose);
      resolve(value);
    }
    socket.on("message", onMessage);
    socket.on("close", onClose);
  });
}

// `onMessage` is attached before Register goes out: the relay sends
// `Incoming` right after `Registered`, often in the same read, and a handler
// attached after `registered` resolves would miss it.
async function register(slot, onMessage) {
  const bearer = ticket("register", "daemon", slot);
  const socket = await open(`/v1/slots/${slot}/control`, bearer);
  if (onMessage) socket.on("message", (data) => onMessage(socket, JSON.parse(data.toString())));
  const registered = next(socket, (m) => m.type === "registered" || m.type === "error", 10_000);
  send(socket, { type: "register", protocol: PROTOCOL, slot, ticket: bearer });
  const answer = await registered;
  if (answer?.type !== "registered") throw new Error(`register: ${JSON.stringify(answer)}`);
  return socket;
}

async function join(slot, role, incoming) {
  const socket = await open(`/v1/circuits/${incoming.circuit}`, incoming.join_ticket);
  const ready = next(socket, (m) => m.type === "ready" || m.type === "error", JOIN_TIMEOUT_MS);
  send(socket, {
    type: "join",
    protocol: PROTOCOL,
    slot,
    circuit: incoming.circuit,
    lane: incoming.lane,
    generation: incoming.generation,
    ticket: incoming.join_ticket,
    role,
  });
  return { socket, ready };
}

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
