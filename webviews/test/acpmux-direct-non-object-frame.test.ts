// An acpmux frame that is valid JSON but not an object (`null`, `0`) used to throw at the
// `"id" in message` check of the direct client's message callback. It is now dropped like a frame
// that is not JSON: nothing throws, and the reply that follows still settles its request.
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

type Message = { id: number; method: string };
const sessionId = "non-object-frame";
const session = { sessionId, cwd: "/home/dev/project", harness: "codex", status: "idle", updatedAt: 1 };
const groups = {
  groups: [],
  chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
  coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
  batching: { windowMs: 100, maxItems: 32, maxPendingGroups: 64, maxReceipts: 64 },
};

/** An authenticated daemon that answers the handshake and leaves `probe` for the test to answer. */
class ProbeSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  sent: Message[] = [];

  constructor() {
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  send(raw: string): void {
    const message = JSON.parse(raw) as Message;
    this.sent.push(message);
    if (message.method === "probe") return;
    queueMicrotask(() => {
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
      this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
    });
  }

  close(): void {
    this.readyState = 3;
  }
}

const host = {
  protocolVersion: 1 as const,
  transport: "acpmux-websocket" as const,
  endpoint: "ws://non-object.invalid/",
  token: "test",
  sessionId,
};

test("non-object frames are dropped and the pending request still gets its reply", async () => {
  const socket = new ProbeSocket();
  const client = await AcpmuxDirectClient.connect(
    host,
    () => {},
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const request = (client as unknown as { request(method: string, params: unknown): Promise<unknown> }).request(
      "probe",
      {},
    );
    const probe = socket.sent.find((message) => message.method === "probe")!;
    for (const frame of ["null", "0", "true", "[]", '"text"', "{"])
      expect(() => socket.onmessage!({ data: frame })).not.toThrow();

    socket.onmessage!({ data: JSON.stringify({ jsonrpc: "2.0", id: probe.id, result: { ok: true } }) });
    expect(await request).toEqual({ ok: true });
  } finally {
    client.close();
  }
});
