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
  askEarlyOpen,
} from "../src/agent-session/acpmux/chatSnapshot/earlyOpen";

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
  resetPageHostClientForTests();
});

type Envelope = { t: string; id: number; op: string; params?: Record<string, unknown> };

/// The app's page host: answers the handshake (for the app's transport unless `refuse`), one open per
/// handshake (as the Swift host keeps one connection per handshake), and records every call.
function pageHost(options: { refuse?: boolean; handshake?: Promise<void> } = {}) {
  const ops: string[] = [];
  let pending: number | undefined;
  let next = 7;
  const postMessage = async (message: Envelope) => {
    if (message.t !== "call") return { t: "ok", id: message.id, value: null };
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
  return { ops };
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
