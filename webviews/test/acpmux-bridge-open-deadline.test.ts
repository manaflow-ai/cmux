// Leo, 2026-11-11: "Connections dying is a thing to always watch for and mitigate... not only during
// already-connected situations, but at the start too". The pane's acpmux socket over the app's bridge
// (bridgeSocket.ts) waited on `transport.open` for good: a host that took the open and never
// answered left the chat pane connecting, with no error and no retry. The open now has a deadline,
// fails as a refused open does with a retryable `native.timed_out` that names its wait, and a late
// answer's connection is closed instead of left running.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { BridgeSocket } from "../src/agent-session/acpmux/bridgeSocket";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { hostIsReconnecting } from "../src/agent-session/acpmux/hostRetry";
import { AcpWireLog } from "../src/agent-session/acpmux/wire";

/// The open's deadline (bridgeSocket.ts TRANSPORT_OPEN_TIMEOUT_MS), literal so the test reads the
/// same on a base that has none.
const TRANSPORT_OPEN_TIMEOUT_MS = 15_000;

const scope = globalThis as Record<string, unknown>;
const hadWindow = "window" in scope;
const savedWindow = scope.window;
// The page's window is this global, so fake timers drive `window.setTimeout` too.
beforeAll(() => {
  scope.window = globalThis;
});
afterAll(() => {
  if (hadWindow) scope.window = savedWindow;
  else delete scope.window;
});
afterEach(() => {
  jest.useRealTimers();
  jest.restoreAllMocks();
});

type Call = { method: string; params?: Record<string, unknown> };

/// A native host that takes every call and answers none, unless `answer` says otherwise.
function silentHost(answer: (call: Call) => Promise<unknown> | undefined = () => undefined) {
  const calls: Call[] = [];
  const post = <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    const call = { method, params };
    calls.push(call);
    return (answer(call) ?? new Promise<never>(() => {})) as Promise<T>;
  };
  return { calls, post };
}

const flush = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve();
};

test("a transport.open the host never answers fails within the deadline, naming its wait", async () => {
  jest.useFakeTimers();
  const host = silentHost();
  const socket = new BridgeSocket(host.post);
  const seen: string[] = [];
  socket.onerror = () => seen.push("error");
  socket.onclose = (event) => seen.push(`close ${event.code}`);
  jest.advanceTimersByTime(TRANSPORT_OPEN_TIMEOUT_MS - 1);
  expect(seen).toEqual([]);
  jest.advanceTimersByTime(1);
  expect(seen).toEqual(["error", "close 1006"]);
  expect(socket.readyState).toBe(BridgeSocket.CLOSED);
  expect(socket.closeError).toBe("transport.open_timed_out");
  const error = socket.openError as { code?: string; details?: { wait?: string }; message: string };
  expect(error.code).toBe("native.timed_out");
  expect(error.details?.wait).toBe("transport.open");
  expect(error.message).toContain("transport.open");
  // The pane's handshake loop reads it as a recovery, not a refusal with instructions.
  expect(hostIsReconnecting(error)).toBe(true);
});

test("a connection the host answers after the deadline is closed, not left running", async () => {
  jest.useFakeTimers();
  let answer!: (reply: { connection: number }) => void;
  const host = silentHost((call) =>
    call.method === "transport.open" ? new Promise((resolve) => (answer = resolve)) : Promise.resolve(null),
  );
  const socket = new BridgeSocket(host.post);
  let opened = false;
  socket.onopen = () => (opened = true);
  jest.advanceTimersByTime(TRANSPORT_OPEN_TIMEOUT_MS);
  answer({ connection: 41 });
  await flush();
  expect(opened).toBe(false);
  expect(host.calls.map((call) => call.method)).toEqual(["transport.open", "transport.close"]);
  expect(host.calls[1]?.params).toEqual({ connection: 41 });
});

test("an answered open clears the deadline; close before the answer clears it too", async () => {
  jest.useFakeTimers();
  const host = silentHost((call) =>
    call.method === "transport.open" ? Promise.resolve({ connection: 7 }) : undefined,
  );
  const socket = new BridgeSocket(host.post);
  const seen: string[] = [];
  socket.onopen = () => seen.push("open");
  socket.onclose = () => seen.push("close");
  await flush();
  jest.advanceTimersByTime(TRANSPORT_OPEN_TIMEOUT_MS * 2);
  expect(seen).toEqual(["open"]);
  expect(socket.readyState).toBe(BridgeSocket.OPEN);
  expect(jest.getTimerCount()).toBe(0);

  const pending = new BridgeSocket(silentHost().post);
  pending.close();
  expect(jest.getTimerCount()).toBe(0);
  socket.close();
});

const handshake = { protocolVersion: 1, transport: "acpmux-bridge" } as const;

test("the pane's connect over a host that never answers transport.open rejects as reconnecting", async () => {
  jest.useFakeTimers();
  const host = silentHost();
  let settled: { ok: boolean; error?: unknown } | undefined;
  void AcpmuxDirectClient.connect(
    handshake as never,
    () => {},
    () => {},
    () => new BridgeSocket(host.post) as unknown as WebSocket,
    "native",
  ).then(
    (client) => {
      settled = { ok: true };
      client.close();
    },
    (error: unknown) => (settled = { ok: false, error }),
  );
  await flush();
  jest.advanceTimersByTime(TRANSPORT_OPEN_TIMEOUT_MS - 1);
  await flush();
  expect(settled).toBeUndefined();
  jest.advanceTimersByTime(1);
  await flush();
  expect(settled?.ok).toBe(false);
  expect((settled?.error as { code?: string } | undefined)?.code).toBe("native.timed_out");
  expect(hostIsReconnecting(settled?.error)).toBe(true);
});

test("an open whose frames the host then drops ends the handshake as reconnecting", async () => {
  jest.useFakeTimers();
  // The open is answered; every frame after it goes nowhere.
  const host = silentHost((call) =>
    call.method === "transport.open" ? Promise.resolve({ connection: 9 }) : undefined,
  );
  const started = Date.now();
  let settled: { at: number; error?: unknown } | undefined;
  void AcpmuxDirectClient.connect(
    handshake as never,
    () => {},
    () => {},
    () => new BridgeSocket(host.post) as unknown as WebSocket,
    "native",
  ).then(
    (client) => {
      settled = { at: Date.now() };
      client.close();
    },
    (error: unknown) => (settled = { at: Date.now(), error }),
  );
  for (let step = 0; step < 80 && !settled; step++) {
    await flush();
    jest.advanceTimersByTime(500);
  }
  await flush();
  expect(settled?.error).toBeDefined();
  expect(hostIsReconnecting(settled?.error)).toBe(true);
  // The daemon liveness bound (direct.ts): probed after 5 s of silence, given up 15 s later.
  expect(settled!.at - started).toBeLessThanOrEqual(20_500);
});

/// A daemon over a fake socket that answers the handshake reads, then can drop the connection.
function answeringSocket() {
  const sockets: { onclose?: (event: unknown) => void; readyState: number }[] = [];
  const open = () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        const result =
          message.method === "initialize"
            ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } }
            : message.method === "_acpmux/watch"
              ? { sessions: [] }
              : null;
        queueMicrotask(() => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }));
      },
      close() {},
    };
    sockets.push(socket);
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, sockets };
}

test("the pane's own reconnect after a lost daemon is jittered", async () => {
  const scheduled: number[] = [];
  class Wire extends AcpWireLog {
    override lifecycle(event: string, detail?: Record<string, unknown>): void {
      if (event === "reconnect scheduled") scheduled.push(Number(detail?.delayMs));
      super.lifecycle(event, detail);
    }
  }
  const randoms = [0, 1 - Number.EPSILON];
  jest.spyOn(Math, "random").mockImplementation(() => randoms.shift() ?? 0.5);
  const delays: number[] = [];
  for (let index = 0; index < 2; index++) {
    const daemon = answeringSocket();
    const client = await AcpmuxDirectClient.connect(
      { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t" },
      () => {},
      undefined,
      daemon.open,
      "daemon",
      new Wire(),
    );
    const socket = daemon.sockets[0]!;
    socket.readyState = 3;
    socket.onclose?.({ code: 1006, reason: "", wasClean: false });
    delays.push(scheduled.at(-1)!);
    client.close();
  }
  // Two tabs that lost one daemon together ask it again at different times.
  expect(delays).toEqual([125, 250]);
});
