// Leo, 2026-11-11: "Connections dying is a thing to always watch for and mitigate... not only during
// already-connected situations, but at the start too". A page's daemon socket (daemonSocket.ts)
// settled its connect only on open, error or close, and called itself ready on `open`: an upgrade
// that never completed, or a daemon that opened and then read nothing, left Home on "connecting"
// with no error and no retry. The upgrade now has a deadline, and the connect is ready only once
// the daemon answered its first command (`identify`) within it.
import { afterEach, beforeEach, expect, jest, test } from "bun:test";
import { DaemonSocket } from "../src/pages/shared/daemonSocket";

/// The connect's deadline (daemonSocket.ts CONNECT_TIMEOUT_MS), literal so the test reads the same
/// on a base that has none.
const CONNECT_TIMEOUT_MS = 8_000;

class Socket {
  static OPEN = 1;
  static latest: Socket;
  readyState = 0;
  sent: string[] = [];
  closed = false;
  listeners = new Map<string, ((event: Record<string, unknown>) => void)[]>();

  constructor(_url: string) {
    Socket.latest = this;
  }

  addEventListener(type: string, listener: (event: Record<string, unknown>) => void) {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  emit(type: string, event: Record<string, unknown> = {}) {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }

  open() {
    this.readyState = Socket.OPEN;
    this.emit("open");
  }

  send(data: string) {
    this.sent.push(data);
  }

  /// Like a socket whose peer is gone: no close event comes back.
  close() {
    this.closed = true;
    this.readyState = 3;
  }
}

const scope = globalThis as Record<string, unknown>;
const saved = scope.WebSocket;
beforeEach(() => {
  scope.WebSocket = Socket;
  jest.useFakeTimers();
});
afterEach(() => {
  jest.useRealTimers();
  scope.WebSocket = saved;
});

const flush = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve();
};

function track(connecting: Promise<DaemonSocket>) {
  const state: { error?: { code?: string; message?: string }; socket?: DaemonSocket } = {};
  connecting.then(
    (socket) => (state.socket = socket),
    (error: { code?: string; message?: string }) => (state.error = error),
  );
  return state;
}

test("an upgrade that never completes fails the connect within the deadline, and its socket is closed", async () => {
  const state = track(DaemonSocket.connect("ws://localhost", { token: "t" }));
  const socket = Socket.latest;
  jest.advanceTimersByTime(CONNECT_TIMEOUT_MS - 1);
  await flush();
  expect(state.error).toBeUndefined();
  jest.advanceTimersByTime(1);
  await flush();
  expect(state.error?.code).toBe("unreachable");
  expect(state.error?.message).toContain("upgrade");
  expect(socket.closed).toBe(true);
  expect(jest.getTimerCount()).toBe(0);
});

test("a daemon that opens and then answers nothing fails the connect as unresponsive", async () => {
  const state = track(DaemonSocket.connect("ws://localhost", { token: "t" }));
  const socket = Socket.latest;
  socket.open();
  await flush();
  expect(JSON.parse(socket.sent.at(-1)!).cmd).toBe("identify");
  jest.advanceTimersByTime(CONNECT_TIMEOUT_MS - 1);
  await flush();
  expect(state.socket).toBeUndefined();
  expect(state.error).toBeUndefined();
  jest.advanceTimersByTime(1);
  await flush();
  expect(state.error?.code).toBe("unresponsive");
  expect(state.error?.message).toContain("identify");
  expect(socket.closed).toBe(true);
  expect(jest.getTimerCount()).toBe(0);
});

test("a daemon that answers its probe connects, keeps its identity, and leaves no timer", async () => {
  const state = track(DaemonSocket.connect("ws://localhost", { origin: true }));
  const socket = Socket.latest;
  socket.open();
  await flush();
  const probe = JSON.parse(socket.sent.at(-1)!);
  socket.emit("message", { data: JSON.stringify({ id: probe.id, ok: true, data: { capabilities: ["x"] } }) });
  await flush();
  expect(state.socket?.identity.capabilities).toEqual(["x"]);
  expect(jest.getTimerCount()).toBe(0);
});

test("a pairing that waits on the person is not cut by the upgrade deadline", async () => {
  const state = track(
    DaemonSocket.connect("ws://localhost", { pair: { onChallenge: () => {}, onCredential: () => {} } }),
  );
  const socket = Socket.latest;
  socket.open();
  jest.advanceTimersByTime(CONNECT_TIMEOUT_MS * 3);
  await flush();
  expect(state.error).toBeUndefined();
  socket.emit("message", { data: JSON.stringify({ paired: { credential: "c" } }) });
  await flush();
  const probe = JSON.parse(socket.sent.at(-1)!);
  socket.emit("message", { data: JSON.stringify({ id: probe.id, ok: true, data: {} }) });
  await flush();
  expect(state.socket).toBeDefined();
});

test("Home asks a URL daemon that missed its connect deadline again, keeping its credential", async () => {
  const { afterConnectFailure } = await import("../src/pages/home-channels/DaemonGate");
  expect(afterConnectFailure("unresponsive", "url")).toBe("retry");
  expect(afterConnectFailure("unreachable", "url")).toBe("retry");
  expect(afterConnectFailure("disconnected", "url")).toBe("retry");
  expect(afterConnectFailure("auth_rejected", "url")).toBe("forget");
  expect(afterConnectFailure(undefined, "url")).toBe("form");
  expect(afterConnectFailure("unresponsive", "host")).toBe("retry");
});
