// Talks the relay's wire protocol to a running relay Worker (`wrangler dev`):
// mints tickets with the Worker's key, opens slot and circuit sockets, and
// waits for control messages. Used by tests/stale_daemon_bench.mjs and
// tests/relay_do_behavior.mjs.

import { createHmac } from "node:crypto";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const WebSocket = require("ws");

export const PROTOCOL = 5;
const ISSUER = "cmux-relay";

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export const send = (socket, message) => socket.send(JSON.stringify(message));

// A client for the relay at `baseUrl` whose ticket key is `key`.
export function relay(baseUrl, key) {
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

  function next(socket, accept, timeoutMs) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => done(null), timeoutMs);
      const onMessage = (data, isBinary) => {
        if (isBinary) return;
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
    if (onMessage) {
      socket.on("message", (data, isBinary) => {
        if (!isBinary) onMessage(socket, JSON.parse(data.toString()));
      });
    }
    const registered = next(socket, (m) => m.type === "registered" || m.type === "error", 10_000);
    send(socket, { type: "register", protocol: PROTOCOL, slot, ticket: bearer });
    const answer = await registered;
    if (answer?.type !== "registered") throw new Error(`register: ${JSON.stringify(answer)}`);
    return socket;
  }

  async function join(slot, role, incoming, timeoutMs) {
    const socket = await open(`/v1/circuits/${incoming.circuit}`, incoming.join_ticket);
    const ready = next(socket, (m) => m.type === "ready" || m.type === "error", timeoutMs);
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

  // Opens a client control socket and sends Connect (accepts_parked). The
  // returned `answers` lists every control message the socket got.
  async function connect(slot, lane, generation) {
    const bearer = ticket("connect", "client", slot, { lane, generation });
    const socket = await open(`/v1/slots/${slot}/connect`, bearer);
    const answers = [];
    socket.on("message", (data, isBinary) => {
      if (!isBinary) answers.push(JSON.parse(data.toString()));
    });
    send(socket, {
      type: "connect",
      protocol: PROTOCOL,
      slot,
      ticket: bearer,
      lane,
      generation,
      accepts_parked: true,
    });
    return { socket, answers, until: (accept, timeoutMs) => until(socket, answers, accept, timeoutMs) };
  }

  return { ticket, open, next, register, join, connect };
}

// The first message in `seen` that `accept` takes, or the next one `socket`
// gets within `timeoutMs` (null on timeout or close). `seen` must be filled
// by a listener attached before any message could arrive.
export function until(socket, seen, accept, timeoutMs) {
  const already = seen.find(accept);
  if (already) return Promise.resolve(already);
  return new Promise((resolve) => {
    const timer = setTimeout(() => done(null), timeoutMs);
    const onMessage = (data, isBinary) => {
      if (isBinary) return;
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
