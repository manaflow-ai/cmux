// Live model lists (acpmux b1b857fe0ab9): the daemon refreshes a harness's models in the background
// and sends `_acpmux/harnesses_changed`. The pane re-reads `_acpmux/harnesses` and `_acpmux/models`
// on that event (its catalog query is invalidated), so a refreshed list reaches an open picker
// without a poll or a reconnect.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { QueryClient, QueryObserver } from "@tanstack/react-query";
import { followHarnessChanges, harnessCatalogKey } from "./catalog";
import { AcpmuxDirectClient } from "./direct";

type Request = { id?: number; method: string; params: any };

class Socket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static current: Socket;
  readyState = 0;
  sent: Request[] = [];
  onopen?: () => void;
  onclose?: () => void;
  onerror?: () => void;
  onmessage?: (message: { data: string }) => void;
  constructor(readonly url: URL) {
    Socket.current = this;
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string) {
    const request = JSON.parse(raw) as Request;
    this.sent.push(request);
    if (request.id === undefined) return;
    const result = request.method === "_acpmux/watch" ? { sessions: [] } : {};
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id: request.id, result }) }));
  }
  notify(method: string, params: unknown) {
    this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }
  close() {
    this.readyState = 3;
  }
}

const host = {
  protocolVersion: 1,
  transport: "acpmux-websocket",
  endpoint: "ws://127.0.0.1:4100/acp",
  token: "t",
} as const;
const realSocket = globalThis.WebSocket;
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  (globalThis as any).WebSocket = Socket;
  (globalThis as any).window ??= globalThis;
});
afterEach(() => {
  (globalThis as any).WebSocket = realSocket;
});

test("_acpmux/harnesses_changed re-reads the harnesses and their models", async () => {
  const client = await AcpmuxDirectClient.connect(host, () => {});
  const queryClient = new QueryClient();
  let reads = 0;
  const observer = new QueryObserver(queryClient, {
    queryKey: harnessCatalogKey(1),
    queryFn: async () => {
      reads += 1;
      return client.harnesses();
    },
    staleTime: 60_000,
  });
  const stop = observer.subscribe(() => {});
  try {
    followHarnessChanges(client, queryClient, 1);
    await settle();
    await settle();
    expect(reads).toBe(1);
    const asked = () => Socket.current.sent.filter((request) => request.method === "_acpmux/models").length;
    const before = asked();
    Socket.current.notify("_acpmux/harnesses_changed", { harnesses: ["claude", "codex"] });
    await settle();
    await settle();
    expect(reads).toBe(2);
    expect(asked()).toBe(before + 1);
    expect(Socket.current.sent.filter((request) => request.method === "_acpmux/harnesses").length).toBe(2);
    // Other notifications leave the catalog alone.
    Socket.current.notify("_acpmux/session_changed", { kind: "updated", session: { sessionId: "x" } });
    await settle();
    expect(reads).toBe(2);
  } finally {
    stop();
    client.close();
  }
});
