// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end proof against a deployed share worker (default: the shared dev
// instance). Mints real tokens with a local Ed25519 private key, connects a
// fake host and a guest, and walks the whole session flow. Analogous to
// workers/presence/scripts/local-proof.sh.
//
// Usage:
//   bun scripts/dev-proof.ts \
//     --key ~/.secrets/cmux-share-dev-private.pem \
//     [--base wss://cmux-share-dev.debussy.workers.dev] \
//     [--hibernate] [--hibernate-idle-seconds 180]

import { readFileSync } from "node:fs";
import { createPrivateKey, randomBytes, sign as edSign } from "node:crypto";

import {
  BINARY_KIND_BASELINE,
  BINARY_KIND_FORWARDED_INPUT,
  BINARY_KIND_INPUT,
  decodeTerminalFrame,
  encodeTerminalFrame,
  PROTO_VERSION,
  TERMINAL_FRAME_HEADER_BYTES,
  TERMINAL_TRANSPORT_VERSION,
} from "../src/protocol";

const args = process.argv.slice(2);
function arg(name: string, fallback?: string): string {
  const i = args.indexOf(`--${name}`);
  if (i >= 0 && args[i + 1]) return args[i + 1] as string;
  if (fallback !== undefined) return fallback;
  console.error(`missing --${name}`);
  process.exit(1);
}

const base = arg("base", "wss://cmux-share-dev.debussy.workers.dev");
const hibernationProof = args.includes("--hibernate");
const hibernationIdleSeconds = Number(arg("hibernate-idle-seconds", "180"));
if (!Number.isFinite(hibernationIdleSeconds) || hibernationIdleSeconds < 1) {
  throw new Error("--hibernate-idle-seconds must be a positive number");
}
const keyPath = arg("key").replace(/^~/, process.env.HOME ?? "~");
const key = createPrivateKey(readFileSync(keyPath, "utf8"));

const code = [...randomBytes(22)]
  .map((b) => "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"[b % 62])
  .join("");

function mint(sub: string, email: string, host: boolean): string {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (v: Buffer | string) => Buffer.from(v).toString("base64url");
  const input = `${b64(JSON.stringify({ alg: "EdDSA", typ: "JWT" }))}.${b64(
    JSON.stringify({
      iss: "cmux",
      aud: "cmux-share",
      sub,
      email,
      code,
      host,
      protocolVersion: PROTO_VERSION,
      terminalTransportVersion: TERMINAL_TRANSPORT_VERSION,
      // Host tokens here stand in for the create endpoint's token.
      ...(host ? { create: true } : {}),
      iat: now,
      exp: now + 900,
    }),
  )}`;
  return `${input}.${b64(edSign(null, Buffer.from(input), key))}`;
}

const url = (token: string) => `${base}/v2/share/sessions/${code}/ws?token=${token}`;

interface Waiter {
  next(pred: (msg: Record<string, unknown>) => boolean, label: string): Promise<Record<string, unknown>>;
  nextBinary(label: string): Promise<Uint8Array>;
  withholdNextAcks(count: number): void;
  nextWithheldAcks(count: number, label: string): Promise<string[]>;
  sendAck(nonce: string): void;
  ws: WebSocket;
}

function connect(token: string, name: string): Promise<Waiter> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url(token));
    ws.binaryType = "arraybuffer";
    const messages: Record<string, unknown>[] = [];
    const binaries: Uint8Array[] = [];
    let acksToWithhold = 0;
    const withheldAcks: string[] = [];
    let notify: (() => void) | null = null;
    ws.onmessage = (e) => {
      if (typeof e.data === "string") {
        const message = JSON.parse(e.data) as Record<string, unknown>;
        if (message.t === "ack-request") {
          if (typeof message.nonce !== "string" || message.nonce.length === 0) {
            ws.close(4400, "invalid ACK request");
            return;
          }
          if (acksToWithhold > 0) {
            acksToWithhold -= 1;
            withheldAcks.push(message.nonce);
          } else {
            ws.send(JSON.stringify({ t: "ack", nonce: message.nonce }));
          }
        } else {
          messages.push(message);
        }
      } else {
        binaries.push(new Uint8Array(e.data as ArrayBuffer));
      }
      notify?.();
    };
    ws.onerror = () => reject(new Error(`${name}: socket error`));
    ws.onopen = () => {
      resolve({
        ws,
        async next(pred, label) {
          const deadline = Date.now() + 10_000;
          for (;;) {
            const found = messages.find(pred);
            if (found) {
              messages.splice(messages.indexOf(found), 1);
              return found;
            }
            if (Date.now() > deadline) throw new Error(`${name}: timeout waiting for ${label}`);
            await new Promise<void>((r) => {
              notify = r;
              setTimeout(r, 250);
            });
          }
        },
        async nextBinary(label) {
          const deadline = Date.now() + 10_000;
          while (binaries.length === 0) {
            if (Date.now() > deadline) throw new Error(`${name}: timeout waiting for ${label}`);
            await new Promise<void>((r) => {
              notify = r;
              setTimeout(r, 250);
            });
          }
          return binaries.shift() as Uint8Array;
        },
        withholdNextAcks(count) {
          if (!Number.isSafeInteger(count) || count <= 0) {
            throw new Error(`${name}: ACK count must be positive`);
          }
          if (acksToWithhold > 0 || withheldAcks.length > 0) {
            throw new Error(`${name}: an ACK is already being withheld`);
          }
          acksToWithhold = count;
        },
        async nextWithheldAcks(count, label) {
          const deadline = Date.now() + 10_000;
          while (withheldAcks.length < count) {
            if (Date.now() > deadline) throw new Error(`${name}: timeout waiting for ${label}`);
            await new Promise<void>((r) => {
              notify = r;
              setTimeout(r, 250);
            });
          }
          return [...withheldAcks];
        },
        sendAck(nonce) {
          const index = withheldAcks.indexOf(nonce);
          if (index < 0) throw new Error(`${name}: ACK nonce does not match withheld`);
          withheldAcks.splice(index, 1);
          ws.send(JSON.stringify({ t: "ack", nonce }));
        },
      });
    };
  });
}

const PROOF_EPOCH = "12345678-1234-4567-89ab-123456789abc";
const ZERO_EPOCH = "00000000-0000-0000-0000-000000000000";

function encodeBaselineFrame(
  ws: string,
  pane: string,
  payload: Uint8Array,
): Uint8Array {
  return encodeTerminalFrame({
    kind: BINARY_KIND_BASELINE,
    epoch: PROOF_EPOCH,
    sequenceStart: 0n,
    sequenceEnd: 0n,
    rows: 24,
    columns: 80,
    ws,
    pane,
    user: "",
    payload,
  });
}

function encodeSizedBaselineFrame(
  ws: string,
  pane: string,
  totalBytes: number,
): Uint8Array {
  const enc = new TextEncoder();
  const headerBytes =
    TERMINAL_FRAME_HEADER_BYTES +
    enc.encode(ws).byteLength +
    enc.encode(pane).byteLength;
  if (totalBytes <= headerBytes) throw new Error("sized grid frame is too small");
  return encodeBaselineFrame(
    ws,
    pane,
    new Uint8Array(totalBytes - headerBytes),
  );
}

function encodeInputFrame(ws: string, pane: string, payload: Uint8Array): Uint8Array {
  return encodeTerminalFrame({
    kind: BINARY_KIND_INPUT,
    epoch: ZERO_EPOCH,
    sequenceStart: 0n,
    sequenceEnd: 0n,
    rows: 0,
    columns: 0,
    ws,
    pane,
    user: "",
    payload,
  });
}

const step = (label: string) => console.log(`✓ ${label}`);

// 1. Host connects and declares one workspace.
const host = await connect(mint("proof-host", "host@proof.dev", true), "host");
await host.next((m) => m.t === "session-state", "host snapshot");
step("host connected, session created");
host.ws.send(
  JSON.stringify({
    t: "hello",
    proto: PROTO_VERSION,
    shared: [{ id: "ws-1", title: "proof" }],
    layouts: [{ ws: "ws-1", tree: { kind: "pane", pane: "pane-1", content: "terminal", cols: 80, rows: 24 } }],
  }),
);

// 2. Guest connects, waits for approval.
const guest = await connect(mint("proof-guest", "guest@proof.dev", false), "guest");
guest.ws.send(JSON.stringify({ t: "hello", proto: PROTO_VERSION }));
await guest.next((m) => m.t === "access-pending", "access-pending");
const request = await host.next((m) => m.t === "access-request", "access-request");
if (request.email !== "guest@proof.dev") throw new Error("wrong requester email");
step("guest pending, host saw the request");

// 3. Approve as editor; guest gets a snapshot with the shared workspace.
host.ws.send(JSON.stringify({ t: "approve", user: "proof-guest", role: "editor" }));
const snapshot = await guest.next((m) => m.t === "session-state", "guest snapshot");
const shared = snapshot.shared as Array<{ id: string }>;
if (shared[0]?.id !== "ws-1") throw new Error("snapshot missing shared workspace");
step("approval delivered a snapshot");

// 4. Guest subscribes; host is told; a grid frame fans out to the guest.
guest.ws.send(JSON.stringify({ t: "sub", ws: "ws-1", pane: "pane-1" }));
const sub = await host.next((m) => m.t === "guest-sub" && m.count === 1, "guest-sub");
if (sub.pane !== "pane-1") throw new Error("wrong sub pane");
host.ws.send(
  encodeBaselineFrame(
    "ws-1",
    "pane-1",
    new TextEncoder().encode("\u001b[2J\u001b[Hproof"),
  ),
);
const frame = await guest.nextBinary("grid frame");
if (decodeTerminalFrame(frame)?.kind !== BINARY_KIND_BASELINE) {
  throw new Error("wrong binary kind");
}
step("terminal baseline fanned out to the subscribed guest");

// 5. Guest input relays to the host; chat broadcasts; cursors flow.
const inputPayload = new TextEncoder().encode("echo hi\n");
guest.ws.send(encodeInputFrame("ws-1", "pane-1", inputPayload));
const inputFrame = await host.nextBinary("guest terminal input");
const decodedInput = decodeTerminalFrame(inputFrame);
if (
  decodedInput?.kind !== BINARY_KIND_FORWARDED_INPUT ||
  decodedInput.user !== "proof-guest" ||
  !inputPayload.every(
    (byte, index) => inputFrame[decodedInput.payloadOffset + index] === byte,
  )
) {
  throw new Error("wrong forwarded terminal input");
}
guest.ws.send(JSON.stringify({ t: "chat", text: "hello from proof" }));
await host.next((m) => m.t === "chat", "chat");
guest.ws.send(JSON.stringify({ t: "cursor", pos: { ws: "ws-1", pane: "pane-1", x: 0.5, y: 0.5 } }));
await host.next((m) => m.t === "cursor", "cursor");
step("byte-exact terminal input relayed, chat + cursor broadcast");

// Optional deployed-only hibernation proof. Local workerd does not evict
// Durable Objects, so this mode intentionally idles a deployed dev Worker.
if (hibernationProof) {
  const binaryLimit = 1024 * 1024;
  const firstNearLimit = encodeSizedBaselineFrame("ws-1", "pane-1", binaryLimit - 1);
  const secondNearLimit = encodeSizedBaselineFrame("ws-1", "pane-1", binaryLimit - 512);
  guest.withholdNextAcks(2);
  host.ws.send(firstNearLimit);
  await guest.nextBinary("first near-limit grid frame");
  host.ws.send(secondNearLimit);
  await guest.nextBinary("second near-limit grid frame");
  const [wakingNonce, remainingNonce] = await guest.nextWithheldAcks(
    2,
    "near-ceiling ACK requests",
  );
  if (!wakingNonce || !remainingNonce) throw new Error("missing withheld ACK nonce");
  const ackBytes = (nonce: string) =>
    new TextEncoder().encode(JSON.stringify({ t: "ack-request", nonce })).byteLength;
  const outstandingBytes =
    firstNearLimit.byteLength +
    ackBytes(wakingNonce) +
    20 +
    secondNearLimit.byteLength +
    ackBytes(remainingNonce) +
    20;
  if (outstandingBytes >= 2 * 1024 * 1024 || 2 * 1024 * 1024 - outstandingBytes > 1_024) {
    throw new Error(`proof did not reach the delivery-credit ceiling (${outstandingBytes})`);
  }
  step("persisted two withheld grid deliveries within 1 KiB of the 2 MiB ceiling");

  console.log(`… idling ${hibernationIdleSeconds}s for Durable Object eviction`);
  await new Promise((resolve) => setTimeout(resolve, hibernationIdleSeconds * 1_000));
  guest.sendAck(wakingNonce);

  await Promise.all([
    guest.next((m) => m.t === "resync", "guest post-wake resync"),
    host.next((m) => m.t === "resync", "host post-wake resync"),
  ]);
  step("withheld ACK woke the object and both sockets received resync");
  guest.sendAck(remainingNonce);

  host.ws.send(
    JSON.stringify({
      t: "hello",
      proto: PROTO_VERSION,
      shared: [{ id: "ws-1", title: "proof" }],
      layouts: [
        {
          ws: "ws-1",
          tree: {
            kind: "pane",
            pane: "pane-1",
            content: "terminal",
            cols: 80,
            rows: 24,
          },
        },
      ],
    }),
  );
  guest.ws.send(JSON.stringify({ t: "focus", ws: "ws-1" }));
  guest.ws.send(JSON.stringify({ t: "sub", ws: "ws-1", pane: "pane-1" }));
  await host.next(
    (m) => m.t === "guest-sub" && m.pane === "pane-1" && m.count === 1,
    "post-wake guest-sub",
  );
  host.ws.send(
    encodeBaselineFrame(
      "ws-1",
      "pane-1",
      new TextEncoder().encode("\u001b[Hhealthy after wake"),
    ),
  );
  await guest.nextBinary("post-wake grid frame");
  guest.ws.send(JSON.stringify({ t: "chat", text: "healthy after wake" }));
  await host.next(
    (m) => m.t === "chat" && (m.msg as Record<string, unknown>)?.text === "healthy after wake",
    "post-wake chat",
  );
  step("post-wake grid, traffic, and automatic ACKs remained healthy");
}

// 6. Host ends; guest is told and the code is dead.
host.ws.send(JSON.stringify({ t: "end" }));
await guest.next((m) => m.t === "session-ended", "session-ended");
step("session ended cleanly");

const late = new WebSocket(url(mint("proof-late", "late@proof.dev", false)));
await new Promise<void>((resolve, reject) => {
  late.onmessage = (e) => {
    const msg = JSON.parse(e.data as string) as { t?: string };
    if (msg.t === "session-ended") resolve();
    else reject(new Error(`expected session-ended, got ${msg.t}`));
  };
  late.onerror = () => reject(new Error("late guest socket error"));
  setTimeout(() => reject(new Error("timeout waiting for dead-code rejection")), 10_000);
});
late.close();
step("dead code stays dead");

console.log(`\nAll proof steps passed against ${base} (code ${code.slice(0, 6)}…)`);
process.exit(0);
