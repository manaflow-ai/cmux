import { afterEach, beforeEach, expect, test } from "bun:test";
import { DaemonSocket } from "../src/pages/shared/daemonSocket";

// Invoke the registered callbacks directly so an uncaught message error fails the test.
class Socket {
  static OPEN = 1;
  static latest: Socket;
  readyState = Socket.OPEN;
  sent: string[] = [];
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

  frame(data: string) {
    this.emit("message", { data });
  }

  send(data: string) {
    this.sent.push(data);
  }

  close() {
    this.readyState = 3;
    this.emit("close", { code: 1000 });
  }
}

const scope = globalThis as Record<string, unknown>;
const saved = scope.WebSocket;
beforeEach(() => {
  scope.WebSocket = Socket;
});
afterEach(() => {
  Socket.latest?.close();
  scope.WebSocket = saved;
});

const invalidFrames = ["null", "true", "7", '"text"', "[]", "["];

test("pairing ignores non-object frames and still accepts the credential", async () => {
  const challenges: [string, number][] = [];
  const credentials: string[] = [];
  const connecting = DaemonSocket.connect("ws://localhost", {
    pair: {
      onChallenge: (code, expiresIn) => challenges.push([code, expiresIn]),
      onCredential: (credential) => credentials.push(credential),
    },
  });
  const socket = Socket.latest;
  socket.emit("open");
  for (const data of invalidFrames) expect(() => socket.frame(data)).not.toThrow();
  expect(challenges).toEqual([]);
  expect(credentials).toEqual([]);
  socket.frame(JSON.stringify({ pairing: { code: "123456", expires_in: 45 } }));
  socket.frame(JSON.stringify({ paired: { credential: "test-credential" } }));
  await connecting;
  expect(challenges).toEqual([["123456", 45]]);
  expect(credentials).toEqual(["test-credential"]);
});

test("invalid frames preserve pending replies and subsequent events", async () => {
  const connecting = DaemonSocket.connect("ws://localhost", { origin: true });
  const socket = Socket.latest;
  socket.emit("open");
  const client = await connecting;
  const events: Record<string, unknown>[] = [];
  client.onEvent((event) => events.push(event));
  const reply = client.request("identify");
  const request = JSON.parse(socket.sent[0]);
  for (const data of invalidFrames) expect(() => socket.frame(data)).not.toThrow();
  expect(events).toEqual([]);
  socket.frame(JSON.stringify({ id: request.id, ok: true, data: { name: "test" } }));
  await expect(reply).resolves.toEqual({ name: "test" });
  socket.frame(JSON.stringify({ event: "changed" }));
  expect(events).toEqual([{ event: "changed" }]);
});
