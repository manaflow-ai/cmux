// SPDX-License-Identifier: GPL-3.0-or-later
// Live-session guest probe for dogfooding the Mac host: joins an existing
// share session as a guest (token minted directly with the dev private key),
// prints what a browser guest would receive, subscribes to the first terminal
// pane, counts grid frames, and optionally types into the terminal.
//
// Usage:
//   bun scripts/guest-probe.ts --code <code> \
//     --key ~/.secrets/cmux-share-dev-private.pem \
//     [--base wss://cmux-share-dev.debussy.workers.dev] \
//     [--user u-probe] [--email probe@cmux.dev] \
//     [--send "echo hello-from-guest\n"] [--watch-seconds 8]
//
// Joining with the HOST's own user id (--user <host stack id>) skips the
// approval step (self-host guests are auto-approved); any other id parks the
// probe in access-pending until the host clicks Allow in the Mac chat window.

import { readFileSync } from "node:fs";
import { createPrivateKey, sign as edSign } from "node:crypto";

import {
  BINARY_KIND_BASELINE,
  BINARY_KIND_INPUT,
  BINARY_KIND_OUTPUT,
  decodeTerminalFrame,
  encodeTerminalFrame,
  PROTO_VERSION,
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
const code = arg("code");
const user = arg("user", "u-guest-probe");
const email = arg("email", "probe@cmux.dev");
const sendText = arg("send", "");
const watchSeconds = Number(arg("watch-seconds", "8"));
const keyPath = arg("key").replace(/^~/, process.env.HOME ?? "~");
const key = createPrivateKey(readFileSync(keyPath, "utf8"));

const b64 = (v: Buffer | string) => Buffer.from(v).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const signingInput = `${b64(JSON.stringify({ alg: "EdDSA", typ: "JWT" }))}.${b64(
  JSON.stringify({
    iss: "cmux",
    aud: "cmux-share",
    sub: user,
    email,
    code,
    host: false,
    protocolVersion: PROTO_VERSION,
    terminalTransportVersion: TERMINAL_TRANSPORT_VERSION,
    iat: now,
    exp: now + 300,
  }),
)}`;
const token = `${signingInput}.${b64(edSign(null, Buffer.from(signingInput), key))}`;

const ws = new WebSocket(`${base}/v2/share/sessions/${code}/ws?token=${token}`);
ws.binaryType = "arraybuffer";

let gridFrames = 0;
let gridBytes = 0;
let firstPane: { ws: string; pane: string } | null = null;

function findTerminalPane(tree: unknown): { pane: string; cols?: number; rows?: number } | null {
  if (!tree || typeof tree !== "object") return null;
  const node = tree as Record<string, unknown>;
  if (node.kind === "pane") {
    return node.content === "terminal"
      ? { pane: String(node.pane), cols: node.cols as number, rows: node.rows as number }
      : null;
  }
  return findTerminalPane(node.a) ?? findTerminalPane(node.b);
}

ws.onopen = () => {
  ws.send(JSON.stringify({ t: "hello", proto: PROTO_VERSION }));
  console.log(`connected as ${user} <${email}>`);
};

ws.onmessage = (event) => {
  if (typeof event.data !== "string") {
    const bytes = new Uint8Array(event.data as ArrayBuffer);
    const frame = decodeTerminalFrame(bytes);
    if (
      frame?.kind === BINARY_KIND_BASELINE ||
      frame?.kind === BINARY_KIND_OUTPUT
    ) {
      gridFrames += 1;
      gridBytes += bytes.length;
      if (gridFrames === 1) {
        console.log(
          `first terminal frame: ${frame.columns}x${frame.rows} ` +
            `kind=${frame.kind === BINARY_KIND_BASELINE ? "baseline" : "output"} ` +
            `payload=${frame.payloadLength} bytes`,
        );
      }
    }
    return;
  }
  const msg = JSON.parse(event.data) as Record<string, unknown>;
  if (msg.t === "ack-request") {
    if (typeof msg.nonce !== "string" || msg.nonce.length === 0) {
      console.error("invalid ACK request");
      ws.close(4400);
      return;
    }
    ws.send(JSON.stringify({ t: "ack", nonce: msg.nonce }));
    return;
  }
  switch (msg.t) {
    case "access-pending":
      console.log("access-pending: waiting for the host to approve in the Mac chat window…");
      break;
    case "access-denied":
      console.log("access-denied");
      process.exit(2);
      break;
    case "session-state": {
      const shared = msg.shared as Array<{ id: string; title: string }>;
      const layouts = msg.layouts as Array<{ ws: string; tree: unknown }>;
      const participants = msg.participants as Array<Record<string, unknown>>;
      const you = msg.you as Record<string, unknown>;
      console.log(
        `session-state: ${shared.length} workspace(s) [${shared
          .map((w) => w.title || w.id.slice(0, 8))
          .join(", ")}], you=${you.role}/color${you.color}, ` +
          `participants=${participants.map((p) => `${p.email}${p.isHost ? "(host)" : ""}`).join(", ")}`,
      );
      for (const layout of layouts) {
        const pane = findTerminalPane(layout.tree);
        if (pane && !firstPane) {
          firstPane = { ws: layout.ws, pane: pane.pane };
          console.log(
            `subscribing to terminal pane ${pane.pane.slice(0, 8)}… in ws ${layout.ws.slice(0, 8)}… ` +
              `(${pane.cols ?? "?"}x${pane.rows ?? "?"})`,
          );
          ws.send(JSON.stringify({ t: "focus", ws: layout.ws }));
          ws.send(JSON.stringify({ t: "sub", ws: layout.ws, pane: pane.pane }));
          if (sendText) {
            const data = sendText.replace(/\\n/g, "\n");
            setTimeout(() => {
              ws.send(
                encodeTerminalFrame({
                  kind: BINARY_KIND_INPUT,
                  epoch: "00000000-0000-0000-0000-000000000000",
                  sequenceStart: 0n,
                  sequenceEnd: 0n,
                  rows: 0,
                  columns: 0,
                  ws: firstPane!.ws,
                  pane: firstPane!.pane,
                  user: "",
                  payload: new TextEncoder().encode(data),
                }),
              );
              console.log(`sent input: ${JSON.stringify(data)}`);
            }, 1_000);
          }
        }
      }
      if (!firstPane) console.log("no terminal pane found in any shared layout");
      break;
    }
    case "chat": {
      const m = msg.msg as Record<string, unknown>;
      console.log(`chat: ${m.user}: ${m.text}`);
      break;
    }
    case "presence":
      break; // frequent; summarized via session-state
    case "cursor":
      break; // frequent
    case "layout":
      console.log("layout update received");
      break;
    case "session-ended":
      console.log(`session-ended: ${msg.reason}`);
      process.exit(0);
      break;
    default:
      console.log(`<- ${msg.t}`);
  }
};

ws.onclose = (e) => {
  console.log(`socket closed (${e.code})`);
};

setTimeout(() => {
  console.log(
    `\nprobe done: ${gridFrames} grid frame(s), ${(gridBytes / 1024).toFixed(1)} KiB total`,
  );
  ws.close(1000);
  process.exit(gridFrames > 0 ? 0 : 1);
}, watchSeconds * 1_000);
