import { afterEach, beforeEach, expect, test } from "bun:test";
import { BridgeSocket, receiveTransportEvent } from "./bridgeSocket";
import { AcpmuxDirectClient, BRIDGE_URL } from "./direct";
import { devHostParams, devHostReply } from "./devHost";

/// The host side of the bridge (Swift AgentPaneTransport): answers `transport.*` calls and, as the
/// daemon would, answers every request frame with an empty result.
class FakeHost {
  calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
  connection = 7;
  answer = true;
  post = async <T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    this.calls.push({ method, params });
    if (method === "transport.open") return { connection: this.connection } as T;
    if (method === "transport.send" && this.answer) {
      const frames = ((params?.frames as string[] | undefined) ?? []).map((raw) => {
        const { id, method: m } = JSON.parse(raw) as { id?: number; method: string };
        const result = m === "_acpmux/watch" ? { sessions: [] } : {};
        return id === undefined ? undefined : JSON.stringify({ jsonrpc: "2.0", id, result });
      });
      queueMicrotask(() =>
        receiveTransportEvent({ connection: this.connection, frames: frames.filter((f): f is string => !!f) }),
      );
    }
    return null as T;
  };
  get sent(): string[] {
    return this.calls.filter((c) => c.method === "transport.send").flatMap((c) => c.params?.frames as string[]);
  }
}

beforeEach(() => {
  (globalThis as any).window ??= globalThis;
  delete (globalThis as any).cmuxAcpmuxTransport;
});
afterEach(() => {
  delete (globalThis as any).cmuxAcpmuxTransport;
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

test("frames written in one task go to the host in one call, in order", async () => {
  const host = new FakeHost();
  host.answer = false;
  const socket = new BridgeSocket(host.post);
  let opened = false;
  socket.onopen = () => (opened = true);
  await tick();
  expect(opened).toBe(true);
  socket.send("a");
  socket.send("b");
  await tick();
  expect(host.calls.filter((c) => c.method === "transport.send")).toEqual([
    { method: "transport.send", params: { connection: 7, frames: ["a", "b"] } },
  ]);
});

test("host pushes become messages, and the host's close ends the socket with its error", async () => {
  const host = new FakeHost();
  const socket = new BridgeSocket(host.post);
  const got: string[] = [];
  let closed: { code: number } | undefined;
  socket.onmessage = (event) => got.push(event.data);
  socket.onclose = (event) => (closed = event);
  await tick();
  receiveTransportEvent({ connection: 7, frames: ["x", "y"] });
  receiveTransportEvent({ connection: 99, frames: ["not mine"] });
  receiveTransportEvent({
    connection: 7,
    closed: { code: 1008, reason: "inbound overflow", error: "transport.inbound_overflow" },
  });
  expect(got).toEqual(["x", "y"]);
  expect(closed?.code).toBe(1008);
  expect(socket.closeError).toBe("transport.inbound_overflow");
  expect(socket.readyState).toBe(BridgeSocket.CLOSED);
  // A closed connection takes nothing more.
  receiveTransportEvent({ connection: 7, frames: ["late"] });
  expect(got).toEqual(["x", "y"]);
});

test("a refused open fails the socket", async () => {
  const socket = new BridgeSocket(async () => {
    throw Object.assign(new Error("no"), { code: "transport.no_connection" });
  });
  let failed = false;
  socket.onclose = () => (failed = true);
  await tick();
  expect(failed).toBe(true);
});

test("over the bridge the client connects with no endpoint and no token anywhere", async () => {
  const host = new FakeHost();
  const urls: URL[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 2, transport: "acpmux-bridge" },
    () => {},
    () => {},
    (url) => {
      urls.push(url);
      return new BridgeSocket(host.post) as unknown as WebSocket;
    },
  );
  expect(urls.map(String)).toEqual([BRIDGE_URL]);
  const first = JSON.parse(host.sent[0]!);
  expect(first.method).toBe("initialize");
  expect(first.params?._meta?.acpmux?.localAppToken).toBeUndefined();
  expect(JSON.stringify(host.calls)).not.toContain("token");
  client.close();
  await tick();
  expect(host.calls.at(-1)).toEqual({ method: "transport.close", params: { connection: 7 } });
});

test("the browser dev slot still dials the standalone daemon with its token", async () => {
  const params = devHostParams("#endpoint=ws://127.0.0.1:47901/&token=dev-token")!;
  const reply = devHostReply(params, { id: "1", method: "ready" });
  if (!reply.ok) throw new Error("ready failed");
  const host = reply.value as { transport: string; endpoint: string; token: string };
  expect(host.transport).toBe("acpmux-websocket");
  const urls: URL[] = [];
  const bridge = new FakeHost();
  await AcpmuxDirectClient.connect(
    host as never,
    () => {},
    () => {},
    (url) => {
      urls.push(url);
      // A loopback daemon stand-in that answers like the host's fake.
      const socket = new BridgeSocket(bridge.post);
      return socket as unknown as WebSocket;
    },
  );
  expect(urls[0]?.origin + urls[0]?.pathname).toBe("ws://127.0.0.1:47901/");
  expect(urls[0]?.searchParams.get("token")).toBe("dev-token");
});
