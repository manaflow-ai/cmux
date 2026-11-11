// Behavior tests for the relay's Durable Objects, run against the real Worker
// under `wrangler dev`: RelaySlot and RelayCircuit hold workerd WebSockets
// and storage, which `cargo test` cannot drive.
//
// Usage: node tests/relay_do_behavior.mjs URL KEY
// Prints one line per check and exits 1 if any check failed.

import { randomBytes } from "node:crypto";

import { relay, send, sleep, until } from "./relay_harness.mjs";

const [, , baseUrl, key] = process.argv;
if (!baseUrl || !key) {
  console.error("usage: node tests/relay_do_behavior.mjs URL KEY");
  process.exit(2);
}

// crate::daemon::DAEMON_LIVENESS_WINDOW_MS
const LIVENESS_WINDOW_MS = 15_000;
const JOIN_WAIT_MS = 40_000;
const r = relay(baseUrl, key);
let failed = 0;

function check(test, name, ok, detail) {
  if (!ok) failed += 1;
  const suffix = ok || detail === undefined ? "" : ` (${JSON.stringify(detail)})`;
  console.log(`${ok ? "ok  " : "FAIL"} ${test}: ${name}${suffix}`);
}

const newSlot = (name) => `behavior-${name}-${randomBytes(6).toString("hex")}`;
const isAnswer = (m) => ["allocated", "parked", "error"].includes(m.type);

// Resolves to the value of `promise`, or to `fallback` after `ms`.
const within = (promise, ms, fallback = null) =>
  Promise.race([promise, sleep(ms).then(() => fallback)]);

// A daemon on `slot` that records every control message in `seen` and joins
// each Incoming unless `drop(message)` says to ignore it. `circuits` maps a
// joined circuit to the daemon's circuit socket.
async function daemon(slot, drop, sockets) {
  const seen = [];
  const circuits = new Map();
  const control = await r.register(slot, (_, message) => {
    seen.push(message);
    if (message.type !== "incoming" || drop(message)) return;
    r.join(slot, "daemon", message, JOIN_WAIT_MS).then(({ socket }) => {
      sockets.push(socket);
      circuits.set(message.circuit, socket);
    }, () => {});
  });
  sockets.push(control);
  return { control, seen, circuits };
}

async function clientJoin(slot, lane, sockets) {
  const client = await r.connect(slot, lane, 1);
  sockets.push(client.socket);
  return client;
}

// (a) The daemon stops reading (a paused machine) right after it registers.
// Connect A arrives inside the liveness window, is allocated, and its
// Incoming is lost. Connect B arrives after the window and parks. The
// daemon then pings again: the relay must hand it A's circuit with a fresh
// join ticket, so A joins, and answer B.
async function resumedPingHandsOverUnjoinedCircuit() {
  const test = "resumed ping";
  const slot = newSlot("resume");
  const sockets = [];
  let deaf = true;
  try {
    const d = await daemon(slot, () => deaf, sockets);
    const registeredAt = Date.now();

    await sleep(2_000);
    const a = await clientJoin(slot, "lane-a", sockets);
    const aAnswer = await a.until(isAnswer, 5_000);
    check(test, "A is allocated inside the liveness window", aAnswer?.type === "allocated", aAnswer);
    if (aAnswer?.type !== "allocated") return;
    const aCircuit = await r.join(slot, "client", aAnswer, JOIN_WAIT_MS);
    sockets.push(aCircuit.socket);
    const lost = await until(
      d.control,
      d.seen,
      (m) => m.type === "incoming" && m.circuit === aAnswer.circuit,
      5_000,
    );
    check(test, "A's first Incoming went to the daemon while it was not reading", lost !== null);

    await sleep(Math.max(0, registeredAt + LIVENESS_WINDOW_MS + 1_500 - Date.now()));
    const b = await clientJoin(slot, "lane-b", sockets);
    const bAnswer = await b.until(isAnswer, 5_000);
    check(test, "B parks while the daemon is silent past the window", bAnswer?.type === "parked", bAnswer);

    deaf = false;
    send(d.control, { type: "ping", nonce: 1 });
    const handedOver = await until(
      d.control,
      d.seen,
      (m) =>
        m.type === "incoming" &&
        m.circuit === aAnswer.circuit &&
        m.join_ticket !== lost?.join_ticket,
      5_000,
    );
    check(test, "the Ping is handed A's circuit with a fresh join ticket", handedOver !== null);
    const aReady = await within(aCircuit.ready, 5_000);
    check(test, "A's client gets Ready", aReady?.type === "ready", aReady);

    const bAllocated = await b.until((m) => m.type === "allocated", 5_000);
    check(test, "B is allocated on the Ping", bAllocated !== null);
    if (bAllocated) {
      const bCircuit = await r.join(slot, "client", bAllocated, JOIN_WAIT_MS);
      sockets.push(bCircuit.socket);
      const bReady = await within(bCircuit.ready, 5_000);
      check(test, "B's client gets Ready", bReady?.type === "ready", bReady);
    }
  } finally {
    for (const socket of sockets) socket.terminate();
  }
}

// (b) A live daemon drops one Incoming (circuit A stays unjoined) and joins
// circuit C. Its routine Ping, well inside the window, must get a Pong and
// nothing else: no Incoming for A, and C keeps forwarding.
async function heartbeatPingHandsOverNothing() {
  const test = "heartbeat ping";
  const slot = newSlot("heartbeat");
  const sockets = [];
  let dropped = null;
  try {
    const d = await daemon(
      slot,
      (m) => {
        if (dropped === null) dropped = m.circuit;
        return m.circuit === dropped;
      },
      sockets,
    );

    const a = await clientJoin(slot, "lane-a", sockets);
    const aAnswer = await a.until(isAnswer, 5_000);
    check(test, "A is allocated", aAnswer?.type === "allocated", aAnswer);
    if (aAnswer?.type !== "allocated") return;
    const aCircuit = await r.join(slot, "client", aAnswer, JOIN_WAIT_MS);
    sockets.push(aCircuit.socket);
    let aSettled = null;
    aCircuit.ready.then((value) => {
      aSettled = value;
    });

    const c = await clientJoin(slot, "lane-c", sockets);
    const cAnswer = await c.until(isAnswer, 5_000);
    check(test, "C is allocated", cAnswer?.type === "allocated", cAnswer);
    if (cAnswer?.type !== "allocated") return;
    const cCircuit = await r.join(slot, "client", cAnswer, JOIN_WAIT_MS);
    sockets.push(cCircuit.socket);
    const cReady = await within(cCircuit.ready, 5_000);
    check(test, "C's client gets Ready", cReady?.type === "ready", cReady);

    const incomingBefore = d.seen.filter((m) => m.type === "incoming").length;
    send(d.control, { type: "ping", nonce: 7 });
    const pong = await until(d.control, d.seen, (m) => m.type === "pong" && m.nonce === 7, 3_000);
    check(test, "the Ping gets a Pong", pong !== null);
    await sleep(2_500);
    const incomingAfter = d.seen.filter((m) => m.type === "incoming").length;
    check(test, "the Ping sends no Incoming", incomingAfter === incomingBefore, {
      before: incomingBefore,
      after: incomingAfter,
    });
    check(test, "A stays unjoined", aSettled === null, aSettled);

    const daemonC = d.circuits.get(cAnswer.circuit);
    check(test, "the daemon holds C's circuit", daemonC !== undefined);
    if (daemonC) {
      const forwarded = new Promise((resolve) =>
        daemonC.once("message", (data, isBinary) => resolve(isBinary ? data.toString() : null)),
      );
      cCircuit.socket.send(Buffer.from("after-ping"));
      const got = await within(forwarded, 3_000);
      check(test, "C still forwards a frame after the Ping", got === "after-ping", got);
    }
  } finally {
    for (const socket of sockets) socket.terminate();
  }
}

await resumedPingHandsOverUnjoinedCircuit();
await heartbeatPingHandsOverNothing();
console.log(failed === 0 ? "relay DO behavior: all checks passed" : `relay DO behavior: ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
