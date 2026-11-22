// l10n-allow-file: test fixtures, not shipped UI.
// Leo, 2026-11-22: "get that gui agent chat sped up to be nearly as fast as the terminal coming back". A
// relaunched chat asked the app for its handshake (`ready`) and its socket (`transport.open`) only once the
// pane's bundle had loaded and run, about 340 ms after the document started. The page's first classic script
// now asks both (chatSnapshot/earlyOpen.ts), and the bundle takes those answers once instead of asking again.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { BridgeSocket } from "../src/agent-session/acpmux/bridgeSocket";
import { postNative } from "../src/agent-session/acpmux/native";
import { resetPageHostClientForTests } from "../src/agent-session/acpmux/pageHost";
import {
  EARLY_OPEN_FRESH_MS,
  EARLY_OPEN_GLOBAL,
  EARLY_RPC_ID,
  askEarlyOpen,
} from "../src/agent-session/acpmux/chatSnapshot/earlyOpen";
import { OPEN_PAGE_BYTES, plainAttach } from "../src/agent-session/acpmux/attachParams";
import { initializeParams } from "../src/agent-session/acpmux/initializeParams";

const scope = globalThis as Record<string, unknown>;
const hadWindow = "window" in scope;
const savedWindow = scope.window;
beforeAll(() => {
  scope.window = globalThis;
});
afterAll(() => {
  if (hadWindow) scope.window = savedWindow;
  else delete scope.window;
});
afterEach(() => {
  jest.useRealTimers();
  delete scope[EARLY_OPEN_GLOBAL];
  delete scope.__cmuxPageParked;
  delete scope.webkit;
  delete scope.cmuxAcpmuxTransport;
  resetPageHostClientForTests();
});

type Envelope = { t: string; id: number; op: string; params?: Record<string, unknown> };

/// The app's page host: answers the handshake (for the app's transport unless `refuse`), one open per
/// handshake (as the Swift host keeps one connection per handshake), and records every call but the
/// socket's sends, whose frames it records in `sent`.
function pageHost(options: { refuse?: boolean; handshake?: Promise<void> } = {}) {
  const ops: string[] = [];
  const sent: string[] = [];
  let pending: number | undefined;
  let next = 7;
  const postMessage = async (message: Envelope) => {
    if (message.t !== "call") return { t: "ok", id: message.id, value: null };
    if (message.op === "cmux.agent.transport.send") {
      sent.push(...((message.params?.frames as string[] | undefined) ?? []));
      return { t: "ok", id: message.id, value: null };
    }
    ops.push(message.op);
    if (message.op === "cmux.agent.handshake") {
      await options.handshake;
      if (options.refuse) return { t: "err", id: message.id, code: "host_unavailable", message: "starting" };
      pending = next++;
      return { t: "ok", id: message.id, value: { transport: "acpmux-bridge", sessionId: "chat" } };
    }
    if (message.op === "cmux.agent.transport.open") {
      if (pending === undefined) return { t: "err", id: message.id, code: "transport.no_connection", message: "none" };
      const connection = pending;
      pending = undefined;
      return { t: "ok", id: message.id, value: { connection } };
    }
    return { t: "ok", id: message.id, value: null };
  };
  scope.webkit = { messageHandlers: { cmuxPage: { postMessage } } };
  return { ops, sent };
}

const settle = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve();
};

test("the bundle's first handshake and its socket take the boot's answers, asking the host nothing again", async () => {
  const host = pageHost();
  askEarlyOpen();
  await settle();
  expect(host.ops).toEqual(["cmux.agent.handshake", "cmux.agent.transport.open"]);
  const ready = await postNative<{ transport?: string }>("ready", {});
  expect(ready.transport).toBe("acpmux-bridge");
  const socket = new BridgeSocket();
  const opened = new Promise<void>((resolve) => (socket.onopen = () => resolve()));
  await opened;
  expect(socket.readyState).toBe(BridgeSocket.OPEN);
  expect(host.ops).toEqual(["cmux.agent.handshake", "cmux.agent.transport.open"]);
  socket.close();
});

test("a refused early handshake is asked again by the bundle, and no socket rode it", async () => {
  const host = pageHost({ refuse: true });
  askEarlyOpen();
  await settle();
  expect(host.ops).toEqual(["cmux.agent.handshake"]);
  await expect(postNative("ready", {})).rejects.toBeDefined();
  expect(host.ops).toEqual(["cmux.agent.handshake", "cmux.agent.handshake"]);
});

test("each answer is taken once: a reconnect's handshake and a second socket ask the host", async () => {
  const host = pageHost();
  askEarlyOpen();
  await settle();
  await postNative("ready", {});
  await postNative("ready", { reconnect: true });
  await postNative("ready", {});
  expect(host.ops.filter((op) => op === "cmux.agent.handshake")).toHaveLength(3);
  const first = new BridgeSocket();
  await new Promise<void>((resolve) => (first.onopen = () => resolve()));
  const second = new BridgeSocket();
  await settle();
  expect(host.ops.filter((op) => op === "cmux.agent.transport.open")).toHaveLength(2);
  first.close();
  second.close();
});

test("an open the bundle never took is closed once the bound passes, and is not taken after it", async () => {
  jest.useFakeTimers();
  let now = 0;
  const host = pageHost();
  askEarlyOpen(() => now);
  await settle();
  expect(host.ops).toEqual(["cmux.agent.handshake", "cmux.agent.transport.open"]);
  now = EARLY_OPEN_FRESH_MS;
  jest.advanceTimersByTime(EARLY_OPEN_FRESH_MS - 1);
  await settle();
  expect(host.ops).not.toContain("cmux.agent.transport.close");
  jest.advanceTimersByTime(1);
  await settle();
  expect(host.ops).toContain("cmux.agent.transport.close");
});

test("the bundle does not take a handshake asked longer ago than the bound", async () => {
  let now = 0;
  const host = pageHost();
  askEarlyOpen(() => now);
  await settle();
  now = EARLY_OPEN_FRESH_MS + 1;
  await postNative("ready", {});
  expect(host.ops.filter((op) => op === "cmux.agent.handshake")).toHaveLength(2);
});

test("a parked spare and a page outside the app ask nothing early", async () => {
  askEarlyOpen();
  expect(scope[EARLY_OPEN_GLOBAL]).toBeUndefined();
  const host = pageHost();
  scope.__cmuxPageParked = true;
  askEarlyOpen();
  await settle();
  expect(host.ops).toEqual([]);
  expect(scope[EARLY_OPEN_GLOBAL]).toBeUndefined();
});

test("a handshake that answers past the bound (a daemon still starting) still hands its socket to the bundle", async () => {
  let now = 0;
  let answer!: () => void;
  const host = pageHost({ handshake: new Promise<void>((resolve) => (answer = resolve)) });
  askEarlyOpen(() => now);
  const ready = postNative("ready", {});
  now = EARLY_OPEN_FRESH_MS + 5_000;
  answer();
  await ready;
  const socket = new BridgeSocket();
  await new Promise<void>((resolve) => (socket.onopen = () => resolve()));
  expect(host.ops).toEqual(["cmux.agent.handshake", "cmux.agent.transport.open"]);
  socket.close();
});

// Leo, 2026-11-22: "where the fuck is the cached thing + delta + simply showing the rendered appearance and the
// bare interactivity or whatever and then gradually loading the rest in but still doing that asap." The boot
// script sends the chat's first requests on the early socket too (`initialize`, then the attach and the draft
// read), and the bundle's same requests take those answers instead of going out again.

/// The pushes the host makes for the early socket, as the app's transport does.
const push = (...frames: unknown[]) =>
  (scope.cmuxAcpmuxTransport as { receive(event: unknown): void }).receive({
    connection: 7,
    frames: frames.map((frame) => JSON.stringify(frame)),
  });
const reply = (id: number, result: unknown) => ({ jsonrpc: "2.0", id, result });
const event = (sessionId: string, seq: number) => ({ jsonrpc: "2.0", method: "_acpmux/event", params: { sessionId, seq } });
const request = (id: number, method: string, params: unknown) => JSON.stringify({ jsonrpc: "2.0", id, method, params });
/// What the boot reads as `visible` here (direct.ts `readerHere`).
const shown = typeof document === "undefined" || document.visibilityState !== "hidden";
const attachOf = (sessionId: string, visible = shown) =>
  plainAttach(sessionId, { settled: false, visible, local: true, maxBytes: OPEN_PAGE_BYTES });
const INIT = { protocolVersion: 1, _meta: { acpmux: { origin: "local" } } };

/// The boot's requests sent and answered (initialize, the attach of "chat", its draft read), with a live
/// record of the chat after the attach's answer; then the bundle's socket, open, recording what it heard.
async function earlyChat(now?: () => number) {
  const host = pageHost();
  askEarlyOpen(now);
  await settle();
  expect(host.sent.map((frame) => JSON.parse(frame).method)).toEqual(["initialize"]);
  push(reply(EARLY_RPC_ID, INIT));
  await settle();
  expect(host.sent.map((frame) => JSON.parse(frame).method)).toEqual([
    "initialize",
    "_acpmux/attach",
    "_acpmux/draft_get",
  ]);
  expect(JSON.parse(host.sent[1]!).params).toEqual(JSON.parse(JSON.stringify(attachOf("chat"))));
  push(reply(EARLY_RPC_ID + 1, { lastSeq: 4, events: [] }), event("chat", 5), reply(EARLY_RPC_ID + 2, { text: "" }));
  await postNative("ready", {});
  const socket = new BridgeSocket();
  const heard: Record<string, unknown>[] = [];
  socket.onmessage = ({ data }) => heard.push(JSON.parse(data));
  await new Promise<void>((resolve) => (socket.onopen = () => resolve()));
  await settle();
  return { host, socket, heard };
}

test("the bundle's initialize, attach and draft read take the boot's answers once, in order, with its ids", async () => {
  const { host, socket, heard } = await earlyChat();
  // Nothing is given before the bundle asks.
  expect(heard).toEqual([]);
  socket.send(request(1, "initialize", initializeParams()));
  await settle();
  expect(heard).toEqual([reply(1, INIT)]);
  socket.send(request(2, "_acpmux/attach", attachOf("chat")));
  socket.send(request(3, "_acpmux/draft_get", { sessionId: "chat" }));
  await settle();
  // A live record after the early answer: given after it, once.
  push(event("chat", 6));
  await settle();
  expect(heard).toEqual([
    reply(1, INIT),
    reply(2, { lastSeq: 4, events: [] }),
    event("chat", 5),
    reply(3, { text: "" }),
    event("chat", 6),
  ]);
  // None of the three went to the host again; a later attach does.
  expect(host.sent).toHaveLength(3);
  socket.send(request(4, "_acpmux/attach", attachOf("chat")));
  await settle();
  expect(host.sent).toHaveLength(4);
  expect(JSON.parse(host.sent[3]!).id).toBe(4);
  socket.close();
});

test("an attach with other params goes out; the boot's answer and the chat's records before it are dropped", async () => {
  const { host, socket, heard } = await earlyChat();
  socket.send(request(1, "initialize", initializeParams()));
  socket.send(request(2, "_acpmux/attach", attachOf("chat", !shown)));
  socket.send(request(3, "_acpmux/draft_get", { sessionId: "chat" }));
  await settle();
  expect(host.sent.slice(3).map((frame) => JSON.parse(frame).id)).toEqual([2]);
  push(reply(2, { lastSeq: 5, events: [] }), event("chat", 6));
  await settle();
  expect(heard).toEqual([reply(1, INIT), reply(3, { text: "" }), reply(2, { lastSeq: 5, events: [] }), event("chat", 6)]);
  socket.close();
});

test("an attach of another chat goes out, and the early chat's records are dropped", async () => {
  const { host, socket, heard } = await earlyChat();
  socket.send(request(1, "initialize", initializeParams()));
  socket.send(request(2, "_acpmux/attach", attachOf("other")));
  socket.send(request(3, "_acpmux/draft_get", { sessionId: "other" }));
  await settle();
  expect(host.sent.slice(3).map((frame) => JSON.parse(frame).method)).toEqual(["_acpmux/attach", "_acpmux/draft_get"]);
  expect(heard).toEqual([reply(1, INIT)]);
  socket.close();
});

test("a request the boot sent longer ago than the bound is not taken: the bundle's goes out", async () => {
  let now = 0;
  const { host, socket, heard } = await earlyChat(() => now);
  socket.send(request(1, "initialize", initializeParams()));
  await settle();
  now = EARLY_OPEN_FRESH_MS + 1;
  socket.send(request(2, "_acpmux/attach", attachOf("chat")));
  await settle();
  expect(host.sent.slice(3).map((frame) => JSON.parse(frame).id)).toEqual([2]);
  push(reply(2, { lastSeq: 6, events: [] }));
  await settle();
  expect(heard).toEqual([reply(1, INIT), reply(2, { lastSeq: 6, events: [] })]);
  socket.close();
});

test("a failed early initialize sends no attach, and the bundle's initialize takes the failure", async () => {
  const host = pageHost();
  askEarlyOpen();
  await settle();
  const failure = { jsonrpc: "2.0", id: EARLY_RPC_ID, error: { code: -32603, message: "starting" } };
  push(failure);
  await settle();
  expect(host.sent).toHaveLength(1);
  await postNative("ready", {});
  const socket = new BridgeSocket();
  const heard: unknown[] = [];
  socket.onmessage = ({ data }) => heard.push(JSON.parse(data));
  await new Promise<void>((resolve) => (socket.onopen = () => resolve()));
  socket.send(request(1, "initialize", initializeParams()));
  await settle();
  expect(heard).toEqual([{ ...failure, id: 1 }]);
  expect(host.sent).toHaveLength(1);
  socket.close();
});

test("a daemon with the row store's hold gets only the draft read early", async () => {
  const host = pageHost();
  askEarlyOpen();
  await settle();
  push(reply(EARLY_RPC_ID, { protocolVersion: 1, _meta: { acpmux: { capabilities: ["attach-hold-v1"] } } }));
  await settle();
  expect(host.sent.map((frame) => JSON.parse(frame).method)).toEqual(["initialize", "_acpmux/draft_get"]);
});

test("once the bundle took the socket the boot sends nothing more", async () => {
  const host = pageHost();
  askEarlyOpen();
  await settle();
  await postNative("ready", {});
  const socket = new BridgeSocket();
  const heard: unknown[] = [];
  socket.onmessage = ({ data }) => heard.push(JSON.parse(data));
  await new Promise<void>((resolve) => (socket.onopen = () => resolve()));
  socket.send(request(1, "initialize", initializeParams()));
  await settle();
  push(reply(EARLY_RPC_ID, INIT));
  await settle();
  expect(heard).toEqual([reply(1, INIT)]);
  expect(host.sent).toHaveLength(1);
  socket.close();
});
