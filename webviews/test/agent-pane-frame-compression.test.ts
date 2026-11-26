// l10n-allow-file: test fixtures, not shipped UI.
// The pane's own socket to an acpmux across a network asks for compressed frames, and reads them
// (Leo: "if im on cellular connection and it's some low tier 5g that bounces to lte ... i should
// still be getting things fast and responsive and flowing, even on ostensibly infinitely long
// chats"). acpmux sends a message of 16 KiB or more as one Binary frame of its zlib stream once
// `initialize` lists `zlib` (cmux-tui/crates/acpmux/src/frame_compress.rs); a long chat's attach
// reply is the frame that matters. The bridge (the app's own loopback socket) never asks: its
// relay's params rule refuses the key (agent-pane-initialize-params-contract.test.ts).
import { expect, test } from "bun:test";
import { deflateSync } from "node:zlib";
import {
  AcpmuxDirectClient,
  frameCompression,
  inflateFrame,
  initializeParams,
} from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000c7";
const START = Date.UTC(2026, 10, 22, 1, 0, 0);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
/// acpmux frame_compress.rs `MIN_BYTES`.
const MIN_BYTES = 16 << 10;

/// Record `seq` (1-based) of a chat of two-record turns: a question and its answer.
function recordAt(seq: number) {
  const turn = Math.floor((seq - 1) / 2);
  const base = { sessionId: CHAT, seq, at: START + turn * 3_000 };
  if ((seq - 1) % 2 === 0) return { ...base, dir: "mux", kind: "user_message", msg: { text: `Question ${turn}` } };
  return {
    ...base,
    dir: "in",
    kind: "agent_message_chunk",
    msg: {
      method: "session/update",
      params: {
        sessionId: "agent-1",
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${turn}: green.` } },
      },
    },
  };
}

/// A stand-in acpmux for one chat of `records` records that compresses as acpmux does: once the
/// connection's `initialize` lists `zlib`, every message of `MIN_BYTES` or more goes as Binary.
function daemon(records: number, options: { closeAfterAttach?: boolean } = {}) {
  const seen = { offered: undefined as unknown, binary: 0, textBytes: 0, binaryBytes: 0, opens: 0 };
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "Long chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: records / 2,
    updatedAt: START,
    lastSeq: records,
  };
  const page = (before: number, limit: number) => {
    const from = Math.max(1, before - limit);
    const events: unknown[] = [];
    for (let seq = from; seq < before; seq += 1) events.push(recordAt(seq));
    return { events, hasMore: from > 1 };
  };
  let compress = false;
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        seen.offered = params?._meta?.acpmux?.compression;
        compress = Array.isArray(seen.offered) && seen.offered.includes("zlib");
        return {
          protocolVersion: 1,
          _meta: { acpmux: { extensions: [], operations: [], ...(compress ? { compression: "zlib" } : {}) } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: records, ...page(records + 1, Number(params?.limit ?? 400)) };
      case "_acpmux/events":
        if (params?.beforeSeq === undefined || params?.promptIndex === true)
          return { events: [], hasMore: false, lastSeq: records };
        return { ...page(Number(params.beforeSeq), Number(params.limit ?? 400)), lastSeq: records };
      default:
        return null;
    }
  };
  const open = () => {
    seen.opens += 1;
    // With `closeAfterAttach`, a reconnect never opens: only the first socket's frames can draw the chat.
    if (options.closeAfterAttach && seen.opens > 1) return { readyState: 0, send() {}, close() {} } as any as WebSocket;
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() => {
          const text = JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            result: answer(message.method, message.params),
          });
          if (compress && text.length >= MIN_BYTES) {
            const zlib = deflateSync(text, { level: 1 });
            seen.binary += 1;
            seen.binaryBytes += zlib.byteLength;
            socket.onmessage?.({ data: zlib.buffer.slice(zlib.byteOffset, zlib.byteOffset + zlib.byteLength) });
          } else {
            seen.textBytes += text.length;
            socket.onmessage?.({ data: text });
          }
          // The link drops right after the attach reply fully arrived: a compressed one is still inflating.
          if (options.closeAfterAttach && message.method === "_acpmux/attach") {
            socket.readyState = 3;
            socket.onclose?.({ code: 1006, reason: "", wasClean: false });
          }
        });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, seen };
}

async function openChat(endpoint: string, records = 4_000, options: { closeAfterAttach?: boolean } = {}) {
  const fake = daemon(records, options);
  let rows = "";
  let connectError: unknown;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint, token: "t", sessionId: CHAT },
    (snapshot) => {
      rows = JSON.stringify(snapshot.rows);
    },
    undefined,
    fake.open,
  ).catch((error: unknown) => {
    connectError = error;
    return undefined;
  });
  for (let n = 0; n < 40; n += 1) await tick();
  client?.dispose();
  return { seen: fake.seen, rows, connectError };
}

test("the page's socket to an acpmux across a network offers zlib frames and reads a compressed attach reply", async () => {
  const { seen, rows } = await openChat("wss://box.example.net/app/ws");
  expect(seen.offered).toEqual(["zlib"]);
  // The long chat's attach reply came compressed, and the newest answer in it is on screen.
  expect(seen.binary).toBeGreaterThan(0);
  expect(rows).toContain("Answer 1999: green.");
});

test("a loopback socket and the app's bridge never offer it", async () => {
  const { seen, rows } = await openChat("ws://127.0.0.1:7777/");
  expect(seen.offered).toBeUndefined();
  expect(seen.binary).toBe(0);
  expect(rows).toContain("Answer 1999: green.");
  expect(frameCompression({ transport: "acpmux-bridge" })).toBe(false);
  expect(frameCompression({ transport: "acpmux-websocket", endpoint: "ws://localhost:1/" })).toBe(false);
  expect(frameCompression({ transport: "acpmux-websocket", endpoint: "ws://[::1]:1/" })).toBe(false);
  // The bridge's initialize is the contract's, without the key its relay would refuse.
  expect(JSON.stringify(initializeParams())).not.toContain("compression");
});

test("inflateFrame reads acpmux's zlib stream through the browser's own decoder", async () => {
  const big = JSON.stringify({ n: 1, pad: "x".repeat(MIN_BYTES) });
  const zlib = deflateSync(big);
  expect(await inflateFrame(zlib.buffer.slice(zlib.byteOffset, zlib.byteOffset + zlib.byteLength))).toBe(big);
});

test("a compressed reply that fully arrived is read even when the socket closes while it inflates", async () => {
  // The same drop on an uncompressed (Text) reply: the reply is read before the close.
  const text = await openChat("ws://127.0.0.1:7777/", 4_000, { closeAfterAttach: true });
  expect(text.seen.binary).toBe(0);
  expect(text.rows).toContain("Answer 1999: green.");
  // A compressed reply is still inflating when the close comes; the chat draws the same rows.
  const zlib = await openChat("wss://box.example.net/app/ws", 4_000, { closeAfterAttach: true });
  expect(zlib.seen.binary).toBe(1);
  expect(zlib.rows).toContain("Answer 1999: green.");
  expect(zlib.rows).toBe(text.rows);
});
