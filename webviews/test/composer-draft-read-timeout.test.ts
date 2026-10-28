// l10n-allow-file: draft fixture text and transport parameters, not shipped UI.
import { expect, jest, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { draftTextActions } from "../src/agent-session/acpmux/draftTextActions";

test("an unanswered daemon draft read releases later local writes and ignores its late reply", async () => {
  const readStarted = Promise.withResolvers<void>();
  const writes: unknown[] = [];
  let answerRead = () => {};
  let socket: {
    readyState: number;
    send(raw: string): void;
    close(): void;
    onopen?: () => void;
    onmessage?: (event: { data: string }) => void;
  };
  const open = () => {
    socket = {
      readyState: WebSocket.OPEN,
      send(raw) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        const answer = (result: unknown) =>
          socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) });
        if (message.method === "_acpmux/draft_get") {
          answerRead = () => answer({ sessionId: "draft-timeout", draft: "stale" });
          readStarted.resolve();
          return;
        }
        if (message.method === "_acpmux/draft_set") writes.push(message.params);
        const result =
          message.method === "initialize"
            ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } }
            : message.method === "_acpmux/watch"
              ? { sessions: [] }
              : null;
        queueMicrotask(() => answer(result));
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as unknown as WebSocket;
  };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t" },
    () => {},
    undefined,
    open,
  );
  const mirrored: unknown[] = [];
  const actions = draftTextActions(client, async (method, params) => {
    if (method === "chat.draftText.set") mirrored.push(params);
    return undefined;
  });
  jest.useFakeTimers();
  try {
    const read = actions["chat.readDraft"]({ sessionId: "draft-timeout" });
    await readStarted.promise;
    const write = actions["chat.writeDraft"]({ sessionId: "draft-timeout", text: "new local" });
    jest.advanceTimersByTime(5_000);
    jest.useRealTimers();
    expect(await read).toBe("new local");
    await write;
    expect(mirrored).toEqual([{ sessionId: "draft-timeout", text: "new local" }]);
    expect(writes).toEqual([{ sessionId: "draft-timeout", text: "new local" }]);
    answerRead();
    expect(mirrored).toEqual([{ sessionId: "draft-timeout", text: "new local" }]);
  } finally {
    jest.useRealTimers();
    client.close();
  }
}, 1_000);
