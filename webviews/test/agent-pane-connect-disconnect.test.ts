// A socket lost during the first permission read used to finish connecting anyway. The pane
// then kept "Permission groups are disconnected" with no client recovery running.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { PERMISSION_GROUP_OPS } from "../src/agent-session/acpmux/permissions/protocol";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = ["window", "document"].map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => Object.assign(scope, { window: dom.window, document: dom.window.document }));
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

type Message = { id: number; method: string; params?: Record<string, unknown> };
const sessionId = "connect-disconnect";
const session = { sessionId, cwd: "/home/dev/project", harness: "codex", status: "idle", updatedAt: 1 };
const groups = {
  groups: [],
  chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
  coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
  batching: { windowMs: 100, maxItems: 32, maxPendingGroups: 64, maxReceipts: 64 },
};

/** An authenticated daemon that drops its socket at a selected handshake request. */
class HandshakeSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Message[] = [];

  constructor(
    private readonly dropAt?: string,
    private readonly refuseGroups = false,
  ) {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    this.sent.push(message);
    queueMicrotask(() => {
      if (message.method === this.dropAt) return this.drop();
      const result =
        message.method === "initialize"
          ? {
              protocolVersion: 1,
              _meta: { acpmux: { origin: "local", operations: Object.values(PERMISSION_GROUP_OPS) } },
            }
          : message.method === "_acpmux/watch"
            ? { sessions: [session] }
            : message.method === "_acpmux/attach"
              ? { session, lastSeq: 0, events: [] }
              : message.method === PERMISSION_GROUP_OPS.groups
                ? groups
                : {};
      const reply =
        message.method === PERMISSION_GROUP_OPS.groups && this.refuseGroups
          ? { error: { code: -32603, message: "Permission read unavailable" } }
          : { result };
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }) });
    });
  }

  drop(): void {
    this.readyState = 3;
    this.onclose?.();
  }

  close(): void {
    this.readyState = 3;
  }
}

const host = {
  protocolVersion: 1 as const,
  transport: "acpmux-websocket" as const,
  endpoint: "ws://connect.invalid/",
  token: "test",
  sessionId,
};

test.each(["initialize", "_acpmux/attach", PERMISSION_GROUP_OPS.groups])(
  "a socket lost during %s rejects the handshake so the host can retry",
  async (dropAt) => {
    const socket = new HandshakeSocket(dropAt);
    const frames: string[] = [];
    let lost = 0;
    let connected: AcpmuxDirectClient | undefined;
    try {
      const attempt = AcpmuxDirectClient.connect(
        host,
        (snapshot) => frames.push(snapshot.connection),
        () => lost++,
        () => socket as unknown as WebSocket,
      );
      // Keep a wrongly accepted client reachable for cleanup on the failing base.
      const outcome = await attempt.then(
        (client) => {
          connected = client;
          return "connected";
        },
        () => "failed",
      );
      expect(outcome).toBe("failed");
      expect(lost).toBe(0);
      expect(frames.at(-1)).not.toBe("connected");

      // The next host attempt reads permissions again and becomes usable without a manual Refresh.
      const fresh = new HandshakeSocket();
      connected = await AcpmuxDirectClient.connect(
        host,
        () => {},
        undefined,
        () => fresh as unknown as WebSocket,
      );
      expect(connected.permissions.state.ready).toBe(true);
      expect(connected.permissions.state.error).toBeUndefined();
    } finally {
      connected?.close();
    }
  },
);

test("closing a replaced client publishes no stale disconnected permission frame", async () => {
  const socket = new HandshakeSocket();
  const frames: string[] = [];
  let lost = 0;
  const client = await AcpmuxDirectClient.connect(
    host,
    (snapshot) => frames.push(snapshot.connection),
    () => lost++,
    () => socket as unknown as WebSocket,
  );
  frames.length = 0;
  client.close();
  socket.drop();
  expect(frames).toEqual([]);
  expect(lost).toBe(0);
});

test("an established socket loss requests one fresh host handshake and stays disconnected", async () => {
  const socket = new HandshakeSocket();
  const frames: string[] = [];
  let lost = 0;
  const client = await AcpmuxDirectClient.connect(
    host,
    (snapshot) => frames.push(snapshot.connection),
    () => lost++,
    () => socket as unknown as WebSocket,
  );
  try {
    frames.length = 0;
    socket.drop();
    expect(lost).toBe(1);
    expect(frames.at(-1)).toBe("disconnected");
  } finally {
    client.close();
  }
});

test("a refused permission read on an open socket remains a recoverable permission error", async () => {
  const socket = new HandshakeSocket(undefined, true);
  const client = await AcpmuxDirectClient.connect(
    host,
    () => {},
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    expect(socket.readyState).toBe(1);
    expect(client.permissions.state.ready).toBe(false);
    expect(client.permissions.state.error).toBe("Permission read unavailable");
  } finally {
    client.close();
  }
});
