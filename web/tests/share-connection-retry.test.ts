import { afterEach, beforeEach, describe, expect, test } from "bun:test";

import {
  normalizeOutboundCursor,
  ShareClient,
} from "../app/[locale]/share/[code]/share-connection";
import {
  BINARY_KIND_GRID,
  MAX_BINARY_MESSAGE_BYTES,
  MAX_CHAT_HISTORY,
  MAX_CURSORS,
  MAX_PARTICIPANTS,
  MAX_SERVER_MESSAGE_BYTES,
  MAX_TERMINAL_INPUT_BYTES,
  utf8ByteLength,
  wireEmail,
  wireId,
} from "../app/[locale]/share/[code]/share-protocol";

const originalFetch = globalThis.fetch;
const originalWebSocket = globalThis.WebSocket;
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;

type ScheduledTimer = {
  readonly callback: (...args: unknown[]) => void;
  readonly delay: number;
  readonly args: readonly unknown[];
};

const scheduledTimers = new Map<number, ScheduledTimer>();
const clients = new Set<ShareClient>();
let nextTimerId = 1;

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  readonly url: string;
  readyState = FakeWebSocket.CONNECTING;
  binaryType: BinaryType = "blob";
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  onSend: ((data: string) => void) | null = null;
  sent: string[] = [];
  closeCalls = 0;
  closedWith: { code: number; reason: string } | null = null;

  constructor(url: string | URL) {
    this.url = String(url);
    FakeWebSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
    this.onSend?.(data);
  }

  open(): void {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.({} as Event);
  }

  close(code = 1000, reason = ""): void {
    if (this.readyState === FakeWebSocket.CLOSED) return;
    this.closeCalls += 1;
    this.closedWith = { code, reason };
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.({ code, reason } as CloseEvent);
  }

  receive(message: unknown): void {
    this.receiveRaw(JSON.stringify(message));
  }

  receiveRaw(data: string): void {
    this.onmessage?.({ data } as MessageEvent);
  }

  receiveBinary(data: unknown): void {
    this.onmessage?.({ data } as MessageEvent);
  }

  serverClose(code: number, reason = "server-close"): void {
    this.close(code, reason);
  }

  messages(): Array<Record<string, unknown>> {
    return this.sent.map((message) => JSON.parse(message) as Record<string, unknown>);
  }
}

beforeEach(() => {
  scheduledTimers.clear();
  clients.clear();
  nextTimerId = 1;
  FakeWebSocket.instances = [];
  globalThis.WebSocket = FakeWebSocket as unknown as typeof WebSocket;
  globalThis.setTimeout = ((
    callback: (...args: unknown[]) => void,
    delay?: number,
    ...args: unknown[]
  ) => {
    const id = nextTimerId;
    nextTimerId += 1;
    scheduledTimers.set(id, {
      callback,
      delay: Number(delay ?? 0),
      args,
    });
    return id as unknown as ReturnType<typeof setTimeout>;
  }) as unknown as typeof setTimeout;
  globalThis.clearTimeout = ((id: ReturnType<typeof setTimeout> | undefined) => {
    scheduledTimers.delete(id as unknown as number);
  }) as typeof clearTimeout;
});

afterEach(() => {
  for (const client of clients) client.stop();
  clients.clear();
  globalThis.fetch = originalFetch;
  globalThis.WebSocket = originalWebSocket;
  globalThis.setTimeout = originalSetTimeout;
  globalThis.clearTimeout = originalClearTimeout;
});

function trackedClient(): ShareClient {
  const client = new ShareClient("code12345678");
  clients.add(client);
  return client;
}

function clientWithActiveSession(): ShareClient {
  const client = trackedClient();
  client.session.update({ status: "active", reconnecting: false });
  return client;
}

function tokenError(
  status: number,
  error: string,
  headers: HeadersInit = {},
): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: {
      "content-type": "application/json",
      ...headers,
    },
  });
}

function tokenSuccess(
  wsUrl = "wss://share.cmux.test/v1/share/sessions/code12345678/ws",
  token = "guest-token",
): Response {
  return new Response(
    JSON.stringify({
      token,
      wsUrl,
    }),
    {
      status: 200,
      headers: { "content-type": "application/json" },
    },
  );
}

function snapshot(role: "editor" | "viewer" = "editor") {
  return {
    t: "session-state",
    proto: 1,
    shared: [{ id: "workspace:1", title: "Chosen" }],
    layouts: [
      {
        ws: "workspace:1",
        tree: {
          kind: "split",
          axis: "h",
          ratio: 0.4,
          a: { kind: "pane", pane: "surface:terminal", content: "terminal" },
          b: {
            kind: "split",
            axis: "v",
            ratio: 0.6,
            a: { kind: "pane", pane: "surface:browser", content: "browser" },
            b: { kind: "pane", pane: "surface:agent", content: "agent" },
          },
        },
      },
    ],
    participants: [
      {
        user: "host",
        email: "host@example.com",
        role: "editor",
        color: 0,
        focusWs: "workspace:1",
        connected: true,
        isHost: true,
      },
      {
        user: "guest",
        email: "guest@example.com",
        role,
        color: 1,
        focusWs: "workspace:1",
        connected: true,
        isHost: false,
      },
    ],
    chat: [
      {
        id: "chat:1",
        user: "host",
        text: "hello",
        ts: 1,
      },
    ],
    you: { user: "guest", role, color: 1, isHost: false },
  };
}

function exactJsonBytes(value: Record<string, unknown>, targetBytes: number): string {
  const empty = JSON.stringify({ ...value, padding: "" });
  const paddingBytes = targetBytes - utf8ByteLength(empty);
  expect(paddingBytes).toBeGreaterThanOrEqual(0);
  const encoded = JSON.stringify({ ...value, padding: "x".repeat(paddingBytes) });
  expect(utf8ByteLength(encoded)).toBe(targetBytes);
  return encoded;
}

function binaryGridFrame(payload: unknown): Uint8Array {
  const encoder = new TextEncoder();
  const ws = encoder.encode("workspace:1");
  const pane = encoder.encode("surface:terminal");
  const body = encoder.encode(
    typeof payload === "string" ? payload : JSON.stringify(payload),
  );
  const frame = new Uint8Array(3 + ws.length + pane.length + body.length);
  let offset = 0;
  frame[offset] = BINARY_KIND_GRID;
  offset += 1;
  frame[offset] = ws.length;
  offset += 1;
  frame.set(ws, offset);
  offset += ws.length;
  frame[offset] = pane.length;
  offset += 1;
  frame.set(pane, offset);
  offset += pane.length;
  frame.set(body, offset);
  return frame;
}

function exactBinaryGridFrame(
  payload: Record<string, unknown>,
  targetBytes: number,
): Uint8Array {
  const empty = binaryGridFrame({ ...payload, padding: "" });
  const paddingBytes = targetBytes - empty.byteLength;
  expect(paddingBytes).toBeGreaterThanOrEqual(0);
  const frame = binaryGridFrame({
    ...payload,
    padding: "x".repeat(paddingBytes),
  });
  expect(frame.byteLength).toBe(targetBytes);
  return frame;
}

function fullGridFrame() {
  return {
    format: "cmux.render-grid.v1",
    surface_id: "surface:terminal",
    state_seq: 1,
    columns: 10,
    rows: 2,
    full: true,
    styles: [{ id: 0 }],
    row_spans: [{ row: 0, column: 0, style_id: 0, text: "accepted" }],
  };
}

function ackMessages(socket: FakeWebSocket): Array<Record<string, unknown>> {
  return socket.messages().filter((message) => message.t === "ack");
}

function retryDelays(): number[] {
  return [...scheduledTimers.values()].map((timer) => timer.delay);
}

async function settle(): Promise<void> {
  for (let turn = 0; turn < 10; turn += 1) {
    await Promise.resolve();
  }
}

async function runOnlyTimer(): Promise<void> {
  const entries = [...scheduledTimers.entries()];
  expect(entries).toHaveLength(1);
  const [id, timer] = entries[0] as [number, ScheduledTimer];
  scheduledTimers.delete(id);
  timer.callback(...timer.args);
  await settle();
}

function pendingResponse(): Promise<Response> {
  return new Promise<Response>(() => {});
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
} {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

async function connectedClient(): Promise<{
  client: ShareClient;
  socket: FakeWebSocket;
}> {
  globalThis.fetch = (async () => tokenSuccess()) as typeof fetch;
  const client = trackedClient();
  client.start();
  await settle();
  const socket = FakeWebSocket.instances[0];
  expect(socket).toBeDefined();
  socket?.open();
  return { client, socket: socket as FakeWebSocket };
}

describe("ShareClient token refresh failures", () => {
  test("retries a transient network error without discarding the active session", async () => {
    let fetchCalls = 0;
    globalThis.fetch = (async () => {
      fetchCalls += 1;
      if (fetchCalls === 1) throw new TypeError("network unavailable");
      return pendingResponse();
    }) as typeof fetch;
    const client = clientWithActiveSession();

    client.start();
    await settle();

    expect(client.session.get().status).toBe("active");
    expect(client.session.get().reconnecting).toBe(true);
    expect(retryDelays()).toEqual([800]);

    await runOnlyTimer();
    expect(fetchCalls).toBe(2);
  });

  for (const retry of [
    { header: "0", delay: 1_000, name: "the one-second minimum" },
    { header: "4", delay: 4_000, name: "the server delay" },
    { header: "7200", delay: 3_600_000, name: "the one-hour maximum" },
  ]) {
    test(`clamps HTTP 429 Retry-After to ${retry.name}`, async () => {
      globalThis.fetch = (async () =>
        tokenError(429, "rate_limited", { "retry-after": retry.header })) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(client.session.get().status).toBe("active");
      expect(client.session.get().reconnecting).toBe(true);
      expect(retryDelays()).toEqual([retry.delay]);
    });
  }

  test("uses exponential backoff for an invalid Retry-After", async () => {
    globalThis.fetch = (async () =>
      tokenError(429, "rate_limited", { "retry-after": "later-ish" })) as typeof fetch;
    const client = clientWithActiveSession();

    client.start();
    await settle();

    expect(client.session.get().status).toBe("active");
    expect(retryDelays()).toEqual([800]);
  });

  for (const status of [500, 502, 503, 504]) {
    test(`retries HTTP ${status} without replacing the active session`, async () => {
      globalThis.fetch = (async () =>
        tokenError(status, "temporary_upstream_failure")) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(client.session.get().status).toBe("active");
      expect(client.session.get().reconnecting).toBe(true);
      expect(retryDelays()).toEqual([800]);
    });
  }

  for (const response of [
    new Response("<html>temporary gateway failure</html>", {
      status: 503,
      headers: { "content-type": "text/html" },
    }),
    new Response("{broken", {
      status: 500,
      headers: { "content-type": "application/json" },
    }),
  ]) {
    test(`retries malformed HTTP ${response.status} bodies`, async () => {
      globalThis.fetch = (async () => response.clone()) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(client.session.get().status).toBe("active");
      expect(client.session.get().reconnecting).toBe(true);
      expect(retryDelays()).toEqual([800]);
    });
  }

  for (const failure of [
    { name: "invalid code", status: 400, error: "invalid_code" },
    { name: "unauthorized auth", status: 401, error: "unauthorized" },
    { name: "forbidden auth", status: 403, error: "forbidden" },
    { name: "missing session", status: 404, error: "not_found" },
    {
      name: "missing share configuration",
      status: 503,
      error: "share_not_configured",
    },
  ]) {
    test(`keeps ${failure.name} failures terminal`, async () => {
      let fetchCalls = 0;
      globalThis.fetch = (async () => {
        fetchCalls += 1;
        return tokenError(failure.status, failure.error);
      }) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(fetchCalls).toBe(1);
      expect(client.session.get().status).toBe("unavailable");
      expect(client.session.get().reconnecting).toBe(false);
      expect(retryDelays()).toEqual([]);
    });
  }

  test("keeps exactly one reconnect timer", async () => {
    globalThis.fetch = (async () => {
      throw new TypeError("offline");
    }) as typeof fetch;
    const client = clientWithActiveSession();

    client.start();
    client.start();
    await settle();

    expect(retryDelays()).toEqual([800]);
  });

  test("stop cancels reconnect timers and ignores a late token response", async () => {
    const first = deferred<Response>();
    const second = deferred<Response>();
    let fetchCalls = 0;
    globalThis.fetch = (() => {
      fetchCalls += 1;
      return fetchCalls === 1 ? first.promise : second.promise;
    }) as typeof fetch;
    const client = trackedClient();

    client.start();
    await settle();
    client.stop();
    client.start();
    await settle();
    first.resolve(tokenSuccess());
    await settle();

    expect(FakeWebSocket.instances).toHaveLength(0);

    second.resolve(tokenSuccess());
    await settle();
    expect(FakeWebSocket.instances).toHaveLength(1);

    client.stop();
    expect(scheduledTimers.size).toBe(0);
  });

  test("rejects a remote cleartext WebSocket before exposing the bearer token", async () => {
    globalThis.fetch = (async () =>
      tokenSuccess("ws://evil.example/v1/share/sessions/code12345678/ws")) as typeof fetch;
    const client = trackedClient();

    client.start();
    await settle();

    expect(FakeWebSocket.instances).toHaveLength(0);
    expect(retryDelays()).toEqual([800]);
    client.stop();
    expect(scheduledTimers.size).toBe(0);
  });

  for (const wsUrl of [
    "ws://localhost:8787/v1/share/sessions/code12345678/ws",
    "ws://127.42.0.9:8787/v1/share/sessions/code12345678/ws",
    "ws://[::1]:8787/v1/share/sessions/code12345678/ws",
  ]) {
    test(`accepts the cleartext loopback WebSocket ${wsUrl}`, async () => {
      globalThis.fetch = (async () => tokenSuccess(wsUrl)) as typeof fetch;
      const client = trackedClient();

      client.start();
      await settle();

      expect(FakeWebSocket.instances).toHaveLength(1);
      const connectedUrl = new URL(FakeWebSocket.instances[0]?.url ?? "");
      expect(connectedUrl.searchParams.get("token")).toBe("guest-token");
      expect(scheduledTimers.size).toBe(0);
    });
  }

  test("accepts an exact 8 KiB bearer token", async () => {
    const token = "x".repeat(8 * 1024);
    globalThis.fetch = (async () =>
      tokenSuccess(
        "wss://share.cmux.test/v1/share/sessions/code12345678/ws",
        token,
      )) as typeof fetch;
    const client = trackedClient();

    client.start();
    await settle();

    expect(FakeWebSocket.instances).toHaveLength(1);
    const connectedUrl = new URL(FakeWebSocket.instances[0]?.url ?? "");
    expect(connectedUrl.searchParams.get("token")).toHaveLength(8 * 1024);
    expect(scheduledTimers.size).toBe(0);
  });

  test("rejects a bearer token over 8 KiB before opening a socket", async () => {
    globalThis.fetch = (async () =>
      tokenSuccess(
        "wss://share.cmux.test/v1/share/sessions/code12345678/ws",
        "x".repeat(8 * 1024 + 1),
      )) as typeof fetch;
    const client = trackedClient();

    client.start();
    await settle();

    expect(FakeWebSocket.instances).toHaveLength(0);
    expect(retryDelays()).toEqual([800]);
    client.stop();
    expect(scheduledTimers.size).toBe(0);
  });
});

describe("ShareClient terminal-only session behavior", () => {
  test("uses only the server-selected workspace and subscribes only terminal leaves", async () => {
    const { client, socket } = await connectedClient();
    const sentBeforeSnapshot = socket.sent.length;
    expect(socket.messages()[0]).toEqual({ t: "hello", proto: 1 });

    socket.receive(snapshot());

    expect(client.session.get().shared).toEqual([{ id: "workspace:1", title: "Chosen" }]);
    expect(client.session.get().activeWs).toBe("workspace:1");
    expect(Object.keys(client.session.get().layouts)).toEqual(["workspace:1"]);
    expect(socket.sent).toHaveLength(sentBeforeSnapshot);

    socket.receive({ t: "ack-request", nonce: "snapshot-order" });

    const messages = socket.messages().slice(sentBeforeSnapshot);
    expect(messages[0]).toEqual({ t: "ack", nonce: "snapshot-order" });
    expect(messages).toContainEqual({ t: "focus", ws: "workspace:1" });
    expect(messages).toContainEqual({
      t: "sub",
      ws: "workspace:1",
      pane: "surface:terminal",
    });
    expect(messages.some((message) => message.t === "sub" && message.pane !== "surface:terminal"))
      .toBe(false);
    expect(messages.some((message) => message.ws === "workspace:2")).toBe(false);
  });

  test("rejects session snapshots from a different protocol version", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot("editor"));
    const before = client.session.get();
    const mismatched = snapshot("viewer");
    mismatched.proto = 2;
    const selected = mismatched.shared[0];
    if (selected) selected.title = "must not apply";

    socket.receive(mismatched);

    expect(client.session.get()).toBe(before);
    expect(client.session.get().you?.role).toBe("editor");
    expect(client.session.get().shared[0]?.title).toBe("Chosen");
  });

  test("blocks viewer input and applies role downgrade before React can rerender", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot("editor"));
    socket.receive({ t: "ack-request", nonce: "editor-snapshot" });

    client.sendInput("workspace:1", "surface:terminal", "first");
    client.sendInput("workspace:1", "surface:browser", "browser input");
    socket.receive({ t: "role-changed", role: "viewer" });
    client.sendInput("workspace:1", "surface:terminal", "blocked immediately");

    const inputMessages = socket.messages().filter((message) => message.t === "input");
    expect(inputMessages).toEqual([
      {
        t: "input",
        ws: "workspace:1",
        pane: "surface:terminal",
        data: "first",
      },
    ]);
    expect(client.session.get().you?.role).toBe("viewer");
  });

  test("bounds terminal input payloads", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot("editor"));
    socket.receive({ t: "ack-request", nonce: "editor-snapshot" });

    client.sendInput(
      "workspace:1",
      "surface:terminal",
      "x".repeat(MAX_TERMINAL_INPUT_BYTES + 1_000),
    );

    const input = socket.messages().find((message) => message.t === "input");
    expect((input?.data as string).length).toBe(MAX_TERMINAL_INPUT_BYTES);
  });

  test("pending state retains no prior session data", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    socket.receive({
      t: "cursor",
      user: "host",
      pos: { ws: "workspace:1", pane: "surface:terminal", x: 0.5, y: 0.5 },
    });

    socket.receive({ t: "access-pending" });

    expect(client.session.get()).toMatchObject({
      status: "pending",
      shared: [],
      layouts: {},
      participants: [],
      chat: [],
      you: null,
      activeWs: null,
    });
    expect(client.cursors.get().size).toBe(0);
  });

  test("rejects Unicode controls in wire ids, identity emails, and outbound panes", async () => {
    expect(wireId("surface:\u0085terminal")).toBe(false);
    expect(wireEmail("guest\u0085@example.com")).toBeNull();
    expect(
      normalizeOutboundCursor(
        {
          ws: "workspace:1",
          pane: "surface:\u0085terminal",
          x: 0.5,
          y: 0.5,
        },
        "workspace:1",
      ),
    ).toBeNull();

    const { socket } = await connectedClient();
    const sentBeforeInvalidPayloads = socket.sent.length;
    socket.receive({
      t: "cursor",
      user: "guest\u0085",
      pos: null,
    });
    socket.receive({ t: "ack-request", nonce: "bad-id" });
    socket.receive({
      t: "access-request",
      user: "guest",
      email: "guest\u0085@example.com",
    });
    socket.receive({ t: "ack-request", nonce: "bad-email" });

    expect(socket.sent).toHaveLength(sentBeforeInvalidPayloads);
  });

  test("retains the host and all 256 permitted guest grants in a snapshot", async () => {
    const { client, socket } = await connectedClient();
    const maximumParticipants = snapshot();
    maximumParticipants.participants = Array.from(
      { length: MAX_PARTICIPANTS },
      (_, index) => ({
        user: index === 0 ? "host" : `guest:${index}`,
        email: index === 0 ? "host@example.com" : `guest${index}@example.com`,
        role: index === 0 ? ("editor" as const) : ("viewer" as const),
        color: index,
        focusWs: "workspace:1",
        connected: index < 32,
        isHost: index === 0,
      }),
    );

    socket.receive(maximumParticipants);

    expect(client.session.get().participants).toHaveLength(MAX_PARTICIPANTS);
    expect(client.session.get().participants.at(-1)?.user).toBe("guest:256");
  });

  test("rejects malformed or oversized authoritative snapshots without ACK", async () => {
    const { client, socket } = await connectedClient();
    const baseline = client.session.get();
    const sentBeforeSnapshots = socket.sent.length;

    const tooManyShared = snapshot();
    tooManyShared.shared.push({ id: "workspace:2", title: "extra" });
    const tooManyLayouts = snapshot();
    const firstLayout = tooManyLayouts.layouts[0];
    if (firstLayout) tooManyLayouts.layouts.push(firstLayout);
    const tooManyParticipants = snapshot();
    tooManyParticipants.participants = Array.from(
      { length: MAX_PARTICIPANTS + 1 },
      (_, index) => ({
        user: `user:${index}`,
        email: `user${index}@example.com`,
        role: "viewer" as const,
        color: index,
        focusWs: "workspace:1",
        connected: true,
        isHost: index === 0,
      }),
    );
    const duplicateParticipants = snapshot();
    const duplicateGuest = duplicateParticipants.participants[1];
    if (duplicateGuest) duplicateParticipants.participants.push({ ...duplicateGuest });
    const invalidFocus = snapshot();
    const focusedGuest = invalidFocus.participants[1];
    if (focusedGuest) focusedGuest.focusWs = "workspace\u0085";
    const invalidEmail = snapshot();
    const emailedGuest = invalidEmail.participants[1];
    if (emailedGuest) emailedGuest.email = "guest\u0085@example.com";
    const tooManyMessages = snapshot();
    tooManyMessages.chat = Array.from({ length: MAX_CHAT_HISTORY + 1 }, (_, index) => ({
      id: `chat:${index}`,
      user: "host",
      text: `message ${index}`,
      ts: index,
    }));
    const duplicateMessages = snapshot();
    const firstMessage = duplicateMessages.chat[0];
    if (firstMessage) duplicateMessages.chat.push({ ...firstMessage });
    const invalidBubble = snapshot();
    const bubbleMessage = invalidBubble.chat[0] as Record<string, unknown> | undefined;
    if (bubbleMessage) {
      bubbleMessage.bubble = {
        ws: "workspace:1",
        pane: "surface\u0085",
        x: 0.5,
        y: 0.5,
      };
    }
    const hostBrowser = snapshot();
    hostBrowser.you.isHost = true;
    const mismatchedLayout = snapshot();
    const mismatched = mismatchedLayout.layouts[0];
    if (mismatched) mismatched.ws = "workspace:other";

    for (const [index, malicious] of [
      tooManyShared,
      tooManyLayouts,
      tooManyParticipants,
      duplicateParticipants,
      invalidFocus,
      invalidEmail,
      tooManyMessages,
      duplicateMessages,
      invalidBubble,
      hostBrowser,
      mismatchedLayout,
    ].entries()) {
      socket.receive(malicious);
      socket.receive({ t: "ack-request", nonce: `rejected-${index}` });
    }

    expect(client.session.get()).toBe(baseline);
    expect(socket.sent).toHaveLength(sentBeforeSnapshots);
  });

  test("bounds cursor collections", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    socket.receive({ t: "ack-request", nonce: "cursor-snapshot" });
    for (let index = 0; index < MAX_CURSORS + 50; index += 1) {
      socket.receive({
        t: "cursor",
        user: `cursor:${index}`,
        pos: { ws: "workspace:1", pane: "surface:terminal", x: 0.5, y: 0.5 },
      });
    }

    expect(client.cursors.get().size).toBe(MAX_CURSORS);
  });

  test("ignores malformed JSON and binary frames without throwing", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const before = client.session.get();

    expect(() => socket.receiveRaw("{broken")).not.toThrow();
    expect(() => socket.receive({ t: "session-state", shared: "wrong" })).not.toThrow();
    expect(() => socket.receiveBinary(new ArrayBuffer(1))).not.toThrow();
    expect(() => socket.receiveBinary(new Uint8Array([1, 1, 0xff, 0]))).not.toThrow();
    expect(() => socket.receiveBinary({ arbitrary: true })).not.toThrow();
    expect(client.session.get()).toEqual(before);
  });

  test("stop cancels cursor timers and closes the socket", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    client.sendCursor({
      ws: "workspace:1",
      pane: "surface:terminal",
      x: 0.5,
      y: 0.5,
    });
    expect(scheduledTimers.size).toBe(1);

    client.stop();

    expect(scheduledTimers.size).toBe(0);
    expect(socket.readyState).toBe(FakeWebSocket.CLOSED);
    expect(socket.closeCalls).toBe(1);
  });
});

describe("ShareClient delivery credit acknowledgements", () => {
  test("accepts a 1 MiB minus one session snapshot before acknowledging it", async () => {
    const { client, socket } = await connectedClient();
    const nearLimit = snapshot();
    nearLimit.chat = Array.from({ length: MAX_CHAT_HISTORY }, (_, index) => ({
      id: `chat:${index}`,
      user: "host",
      text: `message ${index} ${"x".repeat(1_700)}`,
      ts: index,
    }));
    const encoded = exactJsonBytes(
      nearLimit as unknown as Record<string, unknown>,
      MAX_SERVER_MESSAGE_BYTES - 1,
    );
    let chatCountAtAck = -1;
    socket.onSend = (data) => {
      const message = JSON.parse(data) as Record<string, unknown>;
      if (message.t === "ack" && message.nonce === "near-limit") {
        chatCountAtAck = client.session.get().chat.length;
      }
    };

    socket.receiveRaw(encoded);

    expect(client.session.get().chat).toHaveLength(MAX_CHAT_HISTORY);
    expect(client.session.get().chat.at(-1)?.text).toContain("message 499");
    expect(ackMessages(socket)).toEqual([]);

    socket.receive({ t: "ack-request", nonce: "near-limit" });

    expect(chatCountAtAck).toBe(MAX_CHAT_HISTORY);
    expect(ackMessages(socket)).toContainEqual({
      t: "ack",
      nonce: "near-limit",
    });
  });

  test("closes with 1009 at the 1 MiB server JSON boundary", async () => {
    const { client, socket } = await connectedClient();
    const encoded = exactJsonBytes(
      { t: "resync" },
      MAX_SERVER_MESSAGE_BYTES,
    );
    const sentBefore = socket.sent.length;

    socket.receiveRaw(encoded);

    expect(socket.closedWith).toEqual({
      code: 1009,
      reason: "message too large",
    });
    expect(socket.sent).toHaveLength(sentBefore);
    expect(client.session.get().status).toBe("unavailable");
    expect(scheduledTimers.size).toBe(0);
  });

  test("applies a binary grid before acknowledging it", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const model = client.gridFor("workspace:1", "surface:terminal");
    let generationAtAck = -1;
    socket.onSend = (data) => {
      const message = JSON.parse(data) as Record<string, unknown>;
      if (message.t === "ack" && message.nonce === "grid-frame") {
        generationAtAck = model.generation;
      }
    };

    socket.receiveBinary(binaryGridFrame(fullGridFrame()));

    expect(model.ready).toBe(true);
    expect(model.generation).toBe(1);
    expect(ackMessages(socket)).toEqual([]);

    socket.receive({ t: "ack-request", nonce: "grid-frame" });

    expect(generationAtAck).toBe(1);
    expect(ackMessages(socket)).toContainEqual({
      t: "ack",
      nonce: "grid-frame",
    });
  });

  test("sends the resync ACK before deferred replay and FIFO user traffic", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    socket.receive({ t: "ack-request", nonce: "initial-snapshot" });
    const sentBeforeResync = socket.sent.length;

    socket.receive({ t: "resync" });
    client.sendInput("workspace:1", "surface:terminal", "typed-before-ack");
    client.sendChat("chat before ack");

    expect(socket.sent).toHaveLength(sentBeforeResync);

    socket.receive({ t: "ack-request", nonce: "resync-order" });

    expect(socket.messages().slice(sentBeforeResync)).toEqual([
      { t: "ack", nonce: "resync-order" },
      { t: "focus", ws: "workspace:1" },
      { t: "sub", ws: "workspace:1", pane: "surface:terminal" },
      {
        t: "input",
        ws: "workspace:1",
        pane: "surface:terminal",
        data: "typed-before-ack",
      },
      { t: "chat", text: "chat before ack" },
    ]);
  });

  test("invalid and orphan ACK markers flush no deferred messages", async () => {
    const { socket } = await connectedClient();
    const sentBeforeMarkers = socket.sent.length;

    socket.receive({ t: "ack-request", nonce: "orphan" });
    expect(socket.sent).toHaveLength(sentBeforeMarkers);

    socket.receive(snapshot());
    expect(socket.sent).toHaveLength(sentBeforeMarkers);

    socket.receive({ t: "ack-request", nonce: "" });
    socket.receive({ t: "ack-request", nonce: "after-invalid" });

    expect(socket.sent).toHaveLength(sentBeforeMarkers);
  });

  test("a displaced payload drops the older payload's deferred messages", async () => {
    const { client, socket } = await connectedClient();
    const sentBeforeSnapshot = socket.sent.length;
    socket.receive(snapshot());
    client.sendInput("workspace:1", "surface:terminal", "drop this input");
    client.sendChat("drop this chat");

    socket.receive({
      t: "presence",
      participants: snapshot().participants,
    });
    socket.receive({ t: "ack-request", nonce: "newer-payload" });

    expect(socket.messages().slice(sentBeforeSnapshot)).toEqual([
      { t: "ack", nonce: "newer-payload" },
    ]);
  });

  test("connection close discards deferred payload work", async () => {
    const { client, socket } = await connectedClient();
    const sentBeforeSnapshot = socket.sent.length;
    socket.receive(snapshot());

    socket.serverClose(1006);
    socket.receive({ t: "ack-request", nonce: "after-close" });

    expect(socket.sent).toHaveLength(sentBeforeSnapshot);
    expect(retryDelays()).toEqual([800]);
    client.stop();
    expect(scheduledTimers.size).toBe(0);
  });

  test("stop discards deferred payload work before closing the socket", async () => {
    const { client, socket } = await connectedClient();
    const sentBeforeSnapshot = socket.sent.length;
    socket.receive(snapshot());

    client.stop();
    socket.receive({ t: "ack-request", nonce: "after-stop" });

    expect(socket.sent).toHaveLength(sentBeforeSnapshot);
    expect(socket.closedWith).toEqual({ code: 1000, reason: "leaving" });
    expect(scheduledTimers.size).toBe(0);
  });

  test("applies and acknowledges a binary grid at one byte below the 1 MiB limit", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const model = client.gridFor("workspace:1", "surface:terminal");
    const frame = exactBinaryGridFrame(
      fullGridFrame() as Record<string, unknown>,
      MAX_BINARY_MESSAGE_BYTES - 1,
    );
    let generationAtAck = -1;
    socket.onSend = (data) => {
      const message = JSON.parse(data) as Record<string, unknown>;
      if (message.t === "ack" && message.nonce === "near-limit-grid") {
        generationAtAck = model.generation;
      }
    };

    socket.receiveBinary(frame);

    expect(socket.closedWith).toBeNull();
    expect(model.ready).toBe(true);
    expect(model.generation).toBe(1);
    expect(ackMessages(socket)).toEqual([]);

    socket.receive({ t: "ack-request", nonce: "near-limit-grid" });

    expect(generationAtAck).toBe(1);
    expect(ackMessages(socket)).toContainEqual({
      t: "ack",
      nonce: "near-limit-grid",
    });
  });

  test("closes with 1009 at the exact 1 MiB binary boundary", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const model = client.gridFor("workspace:1", "surface:terminal");

    socket.receiveBinary(new Uint8Array(MAX_BINARY_MESSAGE_BYTES));

    expect(socket.closedWith).toEqual({
      code: 1009,
      reason: "binary message too large",
    });
    expect(model.generation).toBe(0);
    expect(ackMessages(socket)).toEqual([]);
    expect(client.session.get().status).toBe("unavailable");
    expect(scheduledTimers.size).toBe(0);
  });

  test("closes with 1009 above the 1 MiB binary boundary", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const model = client.gridFor("workspace:1", "surface:terminal");

    socket.receiveBinary(new Uint8Array(MAX_BINARY_MESSAGE_BYTES + 1).buffer);

    expect(socket.closedWith).toEqual({
      code: 1009,
      reason: "binary message too large",
    });
    expect(model.generation).toBe(0);
    expect(ackMessages(socket)).toEqual([]);
    expect(client.session.get().status).toBe("unavailable");
    expect(scheduledTimers.size).toBe(0);
  });

  test("rejects malformed binary headers, UTF-8 ids, and frame kinds without ACKs", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const model = client.gridFor("workspace:1", "surface:terminal");
    const malformedHeader = new Uint8Array([BINARY_KIND_GRID, 10, 0x61]);
    const malformedUtf8 = new Uint8Array([
      BINARY_KIND_GRID,
      1,
      0xff,
      1,
      0x61,
    ]);
    const unknownKind = binaryGridFrame(fullGridFrame());
    unknownKind[0] = 0x7f;

    for (const [nonce, frame] of [
      ["bad-header", malformedHeader],
      ["bad-utf8", malformedUtf8],
      ["bad-kind", unknownKind],
    ] as const) {
      socket.receiveBinary(frame);
      socket.receive({ t: "ack-request", nonce });
    }

    expect(socket.closedWith).toBeNull();
    expect(model.generation).toBe(0);
    expect(ackMessages(socket)).toEqual([]);
  });

  test("reconnect sends only hello until snapshot ACK precedes rebuilt focus and subs", async () => {
    const { socket } = await connectedClient();
    socket.receive(snapshot());
    socket.receive({ t: "ack-request", nonce: "initial" });
    socket.serverClose(1006);
    await runOnlyTimer();
    const reconnected = FakeWebSocket.instances[1];
    expect(reconnected).toBeDefined();
    reconnected?.open();

    expect(reconnected?.messages()).toEqual([{ t: "hello", proto: 1 }]);
    reconnected?.receive({ t: "ack-request", nonce: "orphaned" });
    expect(reconnected?.messages()).toEqual([{ t: "hello", proto: 1 }]);

    reconnected?.receive(snapshot());
    expect(reconnected?.messages()).toEqual([{ t: "hello", proto: 1 }]);
    reconnected?.receive({ t: "ack-request", nonce: "after-snapshot" });

    expect(reconnected?.messages()).toEqual([
      { t: "hello", proto: 1 },
      { t: "ack", nonce: "after-snapshot" },
      { t: "sub", ws: "workspace:1", pane: "surface:terminal" },
      { t: "focus", ws: "workspace:1" },
    ]);
  });

  test("rejects malformed bounded nonces", async () => {
    const { socket } = await connectedClient();
    socket.receive(snapshot());
    for (const nonce of [
      "",
      "x".repeat(65),
      "bad\u0085nonce",
      "🙂".repeat(17),
      42,
    ]) {
      socket.receive({ t: "resync" });
      socket.receive({ t: "ack-request", nonce });
    }

    expect(ackMessages(socket)).toEqual([]);
  });

  test("does not acknowledge rejected or unknown payloads", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());
    const model = client.gridFor("workspace:1", "surface:terminal");
    const before = client.session.get();

    socket.receiveBinary(binaryGridFrame("{malformed"));
    socket.receive({ t: "ack-request", nonce: "bad-grid" });
    expect(model.generation).toBe(0);
    expect(ackMessages(socket)).toEqual([]);

    for (const [nonce, payload] of [
      [
        "too-many-styles",
        {
          ...fullGridFrame(),
          styles: Array.from({ length: 4_097 }, (_, id) => ({ id })),
        },
      ],
      [
        "too-many-palette-colors",
        {
          ...fullGridFrame(),
          terminal_theme: {
            background: "#000000",
            foreground: "#ffffff",
            cursor: "#ffffff",
            palette: Array.from({ length: 257 }, () => "#000000"),
          },
        },
      ],
      [
        "too-many-cleared-rows",
        {
          ...fullGridFrame(),
          cleared_rows: Array.from({ length: 501 }, () => 0),
        },
      ],
    ] as const) {
      socket.receiveBinary(binaryGridFrame(payload));
      socket.receive({ t: "ack-request", nonce });
    }
    expect(model.generation).toBe(0);
    expect(ackMessages(socket)).toEqual([]);

    socket.receive({ t: "role-changed", role: "owner" });
    socket.receive({ t: "ack-request", nonce: "bad-json" });
    expect(client.session.get()).toBe(before);
    expect(ackMessages(socket)).toEqual([]);

    socket.receive({ t: "future-control", value: true });
    socket.receive({ t: "ack-request", nonce: "unknown-control" });
    expect(ackMessages(socket)).toEqual([]);
  });
});

describe("ShareClient WebSocket close handling", () => {
  for (const code of [4400, 1002, 1008, 1009]) {
    test(`treats protocol close ${code} as terminal unavailable`, async () => {
      const { client, socket } = await connectedClient();
      socket.receive(snapshot());

      socket.serverClose(code);

      expect(client.session.get().status).toBe("unavailable");
      expect(scheduledTimers.size).toBe(0);
      client.stop();
      expect(scheduledTimers.size).toBe(0);
      expect(socket.closeCalls).toBe(1);
    });
  }

  for (const reason of ["delivery_failed", "server_message_too_large"]) {
    test(`treats the ${reason} invariant close as terminal unavailable`, async () => {
      const { client, socket } = await connectedClient();
      socket.receive(snapshot());

      socket.serverClose(1011, reason);

      expect(client.session.get().status).toBe("unavailable");
      expect(scheduledTimers.size).toBe(0);
    });
  }

  test("does not trust an unauthenticated close reason as an auth decision", async () => {
    const { client, socket } = await connectedClient();
    socket.receive(snapshot());

    socket.serverClose(1011, "denied");

    expect(client.session.get().status).toBe("active");
    expect(client.session.get().reconnecting).toBe(true);
    expect(retryDelays()).toEqual([800]);
    client.stop();
    expect(scheduledTimers.size).toBe(0);
  });

  test("escalates and caps retries across immediate slow-client and capacity closes", async () => {
    const { client, socket: firstSocket } = await connectedClient();
    let socket = firstSocket;
    const closes = [
      { code: 4008, reason: "slow_client", delay: 800 },
      { code: 4429, reason: "session_full", delay: 1_600 },
      { code: 4008, reason: "rate_limited", delay: 3_200 },
      { code: 4429, reason: "pending_full", delay: 6_400 },
      { code: 4008, reason: "slow_client", delay: 10_000 },
      { code: 4429, reason: "session_full", delay: 10_000 },
    ];

    for (let index = 0; index < closes.length; index += 1) {
      const close = closes[index] as (typeof closes)[number];
      socket.serverClose(close.code, close.reason);
      expect(retryDelays()).toEqual([close.delay]);
      if (index < closes.length - 1) {
        await runOnlyTimer();
        const reconnected = FakeWebSocket.instances[index + 1];
        expect(reconnected).toBeDefined();
        socket = reconnected as FakeWebSocket;
        socket.open();
      }
    }

    client.stop();
    expect(scheduledTimers.size).toBe(0);
    expect(FakeWebSocket.instances).toHaveLength(closes.length);
  });

  test("resets close backoff only after an accepted active snapshot", async () => {
    const { client, socket: firstSocket } = await connectedClient();
    firstSocket.serverClose(4008, "slow_client");
    expect(retryDelays()).toEqual([800]);

    await runOnlyTimer();
    const secondSocket = FakeWebSocket.instances[1] as FakeWebSocket;
    secondSocket.open();
    secondSocket.serverClose(4008, "slow_client");
    expect(retryDelays()).toEqual([1_600]);

    await runOnlyTimer();
    const stableSocket = FakeWebSocket.instances[2] as FakeWebSocket;
    stableSocket.open();
    stableSocket.receive(snapshot());
    stableSocket.serverClose(4008, "slow_client");

    expect(retryDelays()).toEqual([800]);
    client.stop();
    expect(scheduledTimers.size).toBe(0);
  });
});

describe("ShareClient terminal server states", () => {
  for (const terminal of [
    {
      name: "denial",
      message: { t: "access-denied" },
      status: "denied",
    },
    {
      name: "kick",
      message: { t: "kicked" },
      status: "kicked",
    },
    {
      name: "session end",
      message: { t: "session-ended", reason: "host-stopped" },
      status: "ended",
    },
  ] as const) {
    test(`does not reconnect after ${terminal.name}`, async () => {
      const { client, socket } = await connectedClient();
      socket.receive(snapshot());

      socket.receive(terminal.message);
      socket.serverClose(1006);

      expect(client.session.get().status).toBe(terminal.status);
      expect(client.session.get().reconnecting).toBe(false);
      expect(retryDelays()).toEqual([]);
    });
  }
});
