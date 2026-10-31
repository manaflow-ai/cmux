// A diff WebSocket frame that is not a JSON object (truncated JSON, `null`, `0`, `[]`) used to
// throw out of the socket's message callback before any request settled, so a request whose
// answer was that frame hung forever with the socket still open. It now fails the waiting
// requests with a DiffTransportError, and the next request opens a new socket.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { DiffTransportError, WebSocketDiffTransport } from "../src/diff/transport";
import { FakeEventWebSocket } from "./support/fakeEventWebSocket";

let restore: () => void;
beforeEach(() => {
  restore = FakeEventWebSocket.install();
});
afterEach(() => restore());

async function openRequest(transport: WebSocketDiffTransport) {
  const result = transport.request({ method: "protocolHandshake" });
  const socket = FakeEventWebSocket.instances.at(-1)!;
  const before = socket.sent.length;
  socket.open();
  for (let turn = 0; turn < 10 && socket.sent.length === before; turn++) await Promise.resolve();
  const sent = JSON.parse(socket.sent.at(-1)!) as { id: string };
  return { result, socket, id: sent.id };
}

test.each(['{"id":', "null", "0", "[]", '"text"'])(
  "a %s frame fails the waiting request instead of throwing",
  async (frame) => {
    const transport = new WebSocketDiffTransport("ws://diff.invalid/", 1);
    const { result, socket } = await openRequest(transport);
    const settled = result.then(
      () => "resolved",
      (error: unknown) => error,
    );

    expect(() => socket.message(frame)).not.toThrow();

    const error = await settled;
    expect(error).toBeInstanceOf(DiffTransportError);
    expect((error as DiffTransportError).code).toBe("invalidResponse");
    expect(socket.readyState).toBe(FakeEventWebSocket.CLOSED);
    transport.close();
  },
);

test("the request after a malformed frame reconnects and gets its answer", async () => {
  const transport = new WebSocketDiffTransport("ws://diff.invalid/", 1);
  const first = await openRequest(transport);
  first.result.catch(() => {});
  first.socket.message("null");

  const second = await openRequest(transport);
  expect(second.socket).not.toBe(first.socket);
  second.socket.message(JSON.stringify({ id: second.id, result: { type: "handshake", value: {} } }));
  expect(await second.result).toEqual({ type: "handshake", value: {} } as never);
  transport.close();
});

test("the dropped socket's late close event leaves the reconnected socket and its request alone", async () => {
  const transport = new WebSocketDiffTransport("ws://diff.invalid/", 1);
  const first = await openRequest(transport);
  first.result.catch(() => {});
  first.socket.holdClose = true;
  first.socket.message("null");
  expect(first.socket.readyState).toBe(FakeEventWebSocket.CLOSING);

  const second = await openRequest(transport);
  expect(second.socket).not.toBe(first.socket);
  first.socket.finishClose();

  second.socket.message(JSON.stringify({ id: second.id, result: { type: "handshake", value: {} } }));
  expect(await second.result).toEqual({ type: "handshake", value: {} } as never);
  transport.close();
});
