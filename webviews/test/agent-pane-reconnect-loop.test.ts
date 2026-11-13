// A connection that drops right after it connects is not a recovery (Leo, 2026-11-12, of the agent
// chat in his NIGHTLY: "this loop is just so fundamentally fucking stupid like it's just so asinine
// that anything this fucking broken could ever fucking ship"). The pane reloaded and reconnected
// over and over, and drew the chat anew on every connect.
//
// Both reconnect paths started their backoff over the moment a connection succeeded: the client's
// own (`direct.ts` `scheduleReconnect`) and the pane's fresh handshake after `onLost` (App.tsx
// `retryDelay`). A daemon that accepts the pane and then drops it (a crash after attach, a socket
// the bridge replaces, a liveness check that gives up) was asked again every 250 ms, forever. The
// backoff now starts over only after a connection stayed up (hostRetry.ts `lostRetryDelay`).
//
// The test drives the client's own reconnect path against a daemon that drops every connection as
// soon as the pane says it is connected, and counts the connections in a fixed window.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

/// How long the flapping daemon runs. A backoff that keeps growing opens at most five connections
/// in it (the first, then after 250, 500, 1 000 and 2 000 ms); one that starts over at every
/// connect opened one every 250 ms and the connect's own time.
const WINDOW_MS = 4_000;
const MOST_CONNECTIONS = 6;

test("a daemon that drops the pane right after every connect is not asked again every 250 ms", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  type Socket = InstanceType<typeof MockAcpmuxSocket> & { onclose: (() => void) | null };
  const sockets: Socket[] = [];
  const dropped = new Set<Socket>();
  const connectedAt: number[] = [];
  const started = performance.now();
  // The daemon drops the connection on the first snapshot that says it connected.
  const listener = (snapshot: { connection: string }) => {
    const socket = sockets.at(-1);
    if (snapshot.connection !== "connected" || !socket || dropped.has(socket)) return;
    dropped.add(socket);
    connectedAt.push(performance.now() - started);
    setTimeout(() => {
      socket.close();
      socket.onclose?.();
    }, 0);
  };
  const client = await AcpmuxDirectClient.connect(mockHost, listener, undefined, () => {
    const socket = new MockAcpmuxSocket(() => Promise.resolve()) as Socket;
    sockets.push(socket);
    return socket as unknown as WebSocket;
  });
  try {
    // fixed-wait: the window is the measurement: connections are counted over WINDOW_MS of real time.
    await new Promise((resolve) => setTimeout(resolve, WINDOW_MS));
  } finally {
    client.close?.();
  }
  const gaps = connectedAt.slice(1).map((at, i) => Math.round(at - connectedAt[i]!));
  if (sockets.length > MOST_CONNECTIONS)
    console.error(`connections ${sockets.length}, waits between them ${gaps.join(", ")}`);
  expect(sockets.length).toBeLessThanOrEqual(MOST_CONNECTIONS);
});

// The pane's fresh handshake after `onLost` (App.tsx) takes its waits from the same rule. Run it
// for five minutes of a daemon that drops the pane 100 ms after every connect: it is asked about
// once every 10 s, not four times a second.
test("the pane's handshakes after a lost client back off while the daemon keeps dropping it", async () => {
  const { lostRetryDelay, FLAP_RETRY_MAX_MS, RETRY_FIRST_MS } = await import("../src/agent-session/acpmux/hostRetry");
  let delay = RETRY_FIRST_MS;
  let now = 0;
  let connects = 0;
  while (now < 300_000) {
    connects += 1;
    now += 100;
    const lost = lostRetryDelay(delay, 100);
    now += lost.wait;
    delay = lost.next;
  }
  expect(delay).toBe(FLAP_RETRY_MAX_MS);
  expect(connects).toBeLessThanOrEqual(40);
});

test("a connection that stayed up is reconnected at once when it drops, whatever came before", async () => {
  const { lostRetryDelay, CONNECTION_STABLE_MS, FLAP_RETRY_MAX_MS, RETRY_FIRST_MS } =
    await import("../src/agent-session/acpmux/hostRetry");
  expect(lostRetryDelay(FLAP_RETRY_MAX_MS, CONNECTION_STABLE_MS)).toEqual({
    wait: RETRY_FIRST_MS,
    next: RETRY_FIRST_MS * 2,
  });
  expect(lostRetryDelay(2_000, CONNECTION_STABLE_MS - 1)).toEqual({ wait: 2_000, next: 4_000 });
});
