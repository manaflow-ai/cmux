import { expect, test } from "bun:test";
import { BridgeSocket, receiveTransportEvent } from "./bridgeSocket";

// The host's push carries a seq; the page acks it once the frames ran, and the host waits on that ack
// before the next push (AgentPaneTransport.acked). Without the ack the host pushed on the next turn,
// whatever the page still had to do, so a slow page queued pushes behind a key.

type Call = { method: string; params?: Record<string, unknown> };

async function openSocket(connection: number) {
  const calls: Call[] = [];
  const messages: string[] = [];
  const post = (<T>(method: string, params?: Record<string, unknown>): Promise<T> => {
    calls.push({ method, params });
    return Promise.resolve((method === "transport.open" ? { connection } : {}) as T);
  }) as <T>(method: string, params?: Record<string, unknown>) => Promise<T>;
  const socket = new BridgeSocket(post, 60_000);
  socket.onmessage = (event) => {
    // The ack goes after the frames ran, never before.
    expect(calls.some((c) => c.method === "transport.ack")).toBe(false);
    messages.push(event.data);
  };
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(socket.readyState).toBe(BridgeSocket.OPEN);
  return { socket, calls, messages };
}

test("a push with a seq is acked once its frames ran, with the input state", async () => {
  const { socket, calls, messages } = await openSocket(41);
  receiveTransportEvent({ connection: 41, frames: ["a", "b"], seq: 7 });
  expect(messages).toEqual(["a", "b"]);
  const acks = calls.filter((c) => c.method === "transport.ack");
  expect(acks).toHaveLength(1);
  expect(acks[0]?.params).toMatchObject({ connection: 41, seq: 7, queued: 0 });
  expect(typeof acks[0]?.params?.inputPending).toBe("boolean");
  socket.close();
});

test("an old host's push without a seq, and a close, get no ack", async () => {
  const { calls } = await openSocket(42);
  receiveTransportEvent({ connection: 42, frames: ["a"] });
  receiveTransportEvent({ connection: 42, closed: { code: 1000, reason: "" }, seq: 9 });
  expect(calls.filter((c) => c.method === "transport.ack")).toHaveLength(0);
});
