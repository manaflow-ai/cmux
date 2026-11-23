// Leo, 2026-11-23: "get that gui agent chat sped up to be nearly as fast as the terminal coming back".
// A restarted pane asked the host `ready`, and opened the app's bridge, only after React's first
// commit; earlyConnect.ts asks both when the bundle runs. The first handshake must take those
// answers instead of asking again (Swift hands a seeded prompt out once), the first client must
// hear the early socket's open as a fresh socket's, and an early socket nobody adopts is closed.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { BridgeSocket } from "../src/agent-session/acpmux/bridgeSocket";
import {
  askReady,
  dropEarlyConnect,
  startEarlyConnect,
  takeEarlySocket,
} from "../src/agent-session/acpmux/earlyConnect";
import { setNativeHost } from "../src/agent-session/acpmux/native";

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
  dropEarlyConnect();
  setNativeHost(undefined);
});

type Call = { method: string; params: Record<string, unknown> };

function host(answers: Record<string, () => Promise<unknown>>) {
  const calls: Call[] = [];
  setNativeHost((method, params) => {
    calls.push({ method, params });
    return answers[method]?.() ?? new Promise<never>(() => {});
  });
  return calls;
}

const flush = async () => {
  for (let i = 0; i < 8; i++) await Promise.resolve();
};

test("the first handshake takes the early ready; the next asks again", async () => {
  const calls = host({ ready: () => Promise.resolve({ transport: "acpmux-websocket", prompt: "seeded" }) });
  startEarlyConnect();
  expect(calls.map((c) => c.method)).toEqual(["ready"]);
  expect(await askReady<{ prompt?: string }>(false)).toMatchObject({ prompt: "seeded" });
  expect(calls.map((c) => c.method)).toEqual(["ready"]);
  await askReady(true);
  expect(calls).toEqual([
    { method: "ready", params: {} },
    { method: "ready", params: { reconnect: true } },
  ]);
  // No bridge named: nothing opened early.
  expect(calls.some((c) => c.method === "transport.open")).toBe(false);
});

test("the bridge opens beside the mount and its client hears the open once", async () => {
  const calls = host({
    ready: () => Promise.resolve({ transport: "acpmux-bridge" }),
    "transport.open": () => Promise.resolve({ connection: 7 }),
  });
  startEarlyConnect();
  await flush();
  expect(calls.map((c) => c.method)).toEqual(["ready", "transport.open"]);
  await askReady(false);
  const socket = takeEarlySocket();
  expect(socket?.readyState).toBe(BridgeSocket.OPEN);
  const seen: string[] = [];
  socket!.onopen = () => seen.push("open");
  await flush();
  expect(seen).toEqual(["open"]);
  expect(takeEarlySocket()).toBeUndefined();
  socket!.close();
});

test("an early open that failed tells its client it closed", async () => {
  host({
    ready: () => Promise.resolve({ transport: "acpmux-bridge" }),
    "transport.open": () => Promise.reject(new Error("refused")),
  });
  startEarlyConnect();
  await flush();
  const socket = takeEarlySocket();
  const seen: string[] = [];
  socket!.onopen = () => seen.push("open");
  socket!.onerror = () => seen.push("error");
  socket!.onclose = (event) => seen.push(`close ${event.code}`);
  await flush();
  expect(seen).toEqual(["error", "close 1006"]);
});

test("an early socket nobody adopted is closed at the host", async () => {
  const calls = host({
    ready: () => Promise.resolve({ transport: "acpmux-bridge" }),
    "transport.open": () => Promise.resolve({ connection: 9 }),
    "transport.close": () => Promise.resolve({}),
  });
  startEarlyConnect();
  await flush();
  dropEarlyConnect();
  await flush();
  expect(calls.find((c) => c.method === "transport.close")?.params).toEqual({ connection: 9 });
});

test("a page with no host starts nothing", () => {
  startEarlyConnect();
  expect(takeEarlySocket()).toBeUndefined();
});
