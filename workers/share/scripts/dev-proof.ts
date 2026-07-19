// End-to-end proof against a deployed share worker (default: the shared dev
// instance). Mints real tokens with a local Ed25519 private key, connects a
// fake host and a guest, and walks the whole session flow. Analogous to
// workers/presence/scripts/local-proof.sh.
//
// Usage:
//   bun scripts/dev-proof.ts \
//     --key ~/.secrets/cmux-share-dev-private.pem \
//     [--base wss://cmux-share-dev.debussy.workers.dev]

import { readFileSync } from "node:fs";
import { createPrivateKey, randomBytes, sign as edSign } from "node:crypto";

const args = process.argv.slice(2);
function arg(name: string, fallback?: string): string {
  const i = args.indexOf(`--${name}`);
  if (i >= 0 && args[i + 1]) return args[i + 1] as string;
  if (fallback !== undefined) return fallback;
  console.error(`missing --${name}`);
  process.exit(1);
}

const base = arg("base", "wss://cmux-share-dev.debussy.workers.dev");
const keyPath = arg("key").replace(/^~/, process.env.HOME ?? "~");
const key = createPrivateKey(readFileSync(keyPath, "utf8"));

const code = [...randomBytes(22)]
  .map((b) => "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"[b % 62])
  .join("");

function mint(sub: string, email: string, host: boolean): string {
  const now = Math.floor(Date.now() / 1000);
  const b64 = (v: Buffer | string) => Buffer.from(v).toString("base64url");
  const input = `${b64(JSON.stringify({ alg: "EdDSA", typ: "JWT" }))}.${b64(
    JSON.stringify({ iss: "cmux", aud: "cmux-share", sub, email, code, host, iat: now, exp: now + 300 }),
  )}`;
  return `${input}.${b64(edSign(null, Buffer.from(input), key))}`;
}

const url = (token: string) => `${base}/v1/share/sessions/${code}/ws?token=${token}`;

interface Waiter {
  next(pred: (msg: Record<string, unknown>) => boolean, label: string): Promise<Record<string, unknown>>;
  nextBinary(label: string): Promise<Uint8Array>;
  ws: WebSocket;
}

function connect(token: string, name: string): Promise<Waiter> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url(token));
    ws.binaryType = "arraybuffer";
    const messages: Record<string, unknown>[] = [];
    const binaries: Uint8Array[] = [];
    let notify: (() => void) | null = null;
    ws.onmessage = (e) => {
      if (typeof e.data === "string") messages.push(JSON.parse(e.data));
      else binaries.push(new Uint8Array(e.data as ArrayBuffer));
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
      });
    };
  });
}

function encodeGridFrame(ws: string, pane: string, payload: string): Uint8Array {
  const enc = new TextEncoder();
  const wsB = enc.encode(ws);
  const paneB = enc.encode(pane);
  const payloadB = enc.encode(payload);
  const out = new Uint8Array(3 + wsB.length + paneB.length + payloadB.length);
  let o = 0;
  out[o++] = 0x01;
  out[o++] = wsB.length;
  out.set(wsB, o);
  o += wsB.length;
  out[o++] = paneB.length;
  out.set(paneB, o);
  o += paneB.length;
  out.set(payloadB, o);
  return out;
}

const step = (label: string) => console.log(`✓ ${label}`);

// 1. Host connects and declares one workspace.
const host = await connect(mint("proof-host", "host@proof.dev", true), "host");
await host.next((m) => m.t === "session-state", "host snapshot");
step("host connected, session created");
host.ws.send(
  JSON.stringify({
    t: "hello",
    proto: 1,
    shared: [{ id: "ws-1", title: "proof" }],
    layouts: [{ ws: "ws-1", tree: { kind: "pane", pane: "pane-1", content: "terminal", cols: 80, rows: 24 } }],
  }),
);

// 2. Guest connects, waits for approval.
const guest = await connect(mint("proof-guest", "guest@proof.dev", false), "guest");
guest.ws.send(JSON.stringify({ t: "hello", proto: 1 }));
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
host.ws.send(encodeGridFrame("ws-1", "pane-1", '{"format":"cmux.render-grid.v1"}'));
const frame = await guest.nextBinary("grid frame");
if (frame[0] !== 0x01) throw new Error("wrong binary kind");
step("grid frame fanned out to the subscribed guest");

// 5. Guest input relays to the host; chat broadcasts; cursors flow.
guest.ws.send(JSON.stringify({ t: "input", ws: "ws-1", pane: "pane-1", data: "echo hi\n" }));
const input = await host.next((m) => m.t === "guest-input", "guest-input");
if (input.data !== "echo hi\n") throw new Error("wrong input payload");
guest.ws.send(JSON.stringify({ t: "chat", text: "hello from proof" }));
await host.next((m) => m.t === "chat", "chat");
guest.ws.send(JSON.stringify({ t: "cursor", pos: { ws: "ws-1", pane: "pane-1", x: 0.5, y: 0.5 } }));
await host.next((m) => m.t === "cursor", "cursor");
step("input relayed, chat + cursor broadcast");

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
