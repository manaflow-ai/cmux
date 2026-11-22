import { afterEach, beforeEach, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";

/// A loopback acpmux that answers the open handshake and can drop the socket.
class FakeSocket {
  static OPEN = 1;
  static made: FakeSocket[] = [];
  readyState = 0;
  onopen?: () => void;
  onerror?: () => void;
  onclose?: () => void;
  onmessage?: (message: { data: string }) => void;
  constructor(readonly url: URL) {
    FakeSocket.made.push(this);
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }
  send(raw: string) {
    const { id, method } = JSON.parse(raw) as { id: number; method: string };
    const result = method === "_acpmux/watch" ? { sessions: [] } : {};
    queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, result }) }));
  }
  close() {
    this.readyState = 3;
  }
  drop() {
    this.readyState = 3;
    this.onclose?.();
  }
}

const realSocket = globalThis.WebSocket;
beforeEach(() => {
  FakeSocket.made = [];
  (globalThis as any).WebSocket = FakeSocket;
  (globalThis as any).window ??= globalThis;
});
afterEach(() => {
  (globalThis as any).WebSocket = realSocket;
});

const host = {
  protocolVersion: 1,
  transport: "acpmux-websocket",
  endpoint: "ws://127.0.0.1:4100/acp",
  token: "t",
} as any;

test("a dropped connection hands back to the host once instead of retrying the old endpoint", async () => {
  let lost = 0;
  await AcpmuxDirectClient.connect(
    host,
    () => {},
    () => {
      lost += 1;
    },
  );
  expect(FakeSocket.made.length).toBe(1);
  FakeSocket.made[0]!.drop();
  await new Promise((resolve) => setTimeout(resolve, 600));
  expect(lost).toBe(1);
  expect(FakeSocket.made.length).toBe(1);
});
