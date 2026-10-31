// l10n-allow-file: synthetic relay fixtures, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { EventRecord } from "../direct";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, { had: key in scope, value: scope[key] }]));
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const [key, previous] of saved) {
    if (previous.had) scope[key] = previous.value;
    else delete scope[key];
  }
  dom.window.close();
});

test("the real client exports through pane-authorized events reads on its connected relay", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  let exporting = false;
  const reads: string[] = [];
  const relay = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = relay as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> };
  const answer = daemon.answer.bind(relay);
  daemon.answer = async (method, params) => {
    if (!exporting || !["_acpmux/info", "_acpmux/events"].includes(method)) return answer(method, params);
    reads.push(method);
    if (method === "_acpmux/info") throw new Error("transport.intent_invalid");
    const before = Number(params.beforeSeq ?? 7);
    const events: EventRecord[] = [1, 2, 3, 4, 5, 6]
      .filter((seq) => seq < before)
      .slice(-2)
      .map((seq) => ({
        sessionId: String(params.sessionId),
        seq,
        at: 1792800000000,
        dir: "mux",
        kind: "user_message",
        msg: { text: `Prompt ${seq}` },
      }));
    return { events, lastSeq: 6, hasMore: (events[0]?.seq ?? 1) > 1 };
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => relay as unknown as WebSocket,
  );
  try {
    exporting = true;
    const events = await client.conversationEvents(() => true);
    expect(events.map((event) => event.seq)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(reads).toEqual(Array(4).fill("_acpmux/events"));
  } finally {
    client.close();
  }
});

test("a reconnect during export invalidates the captured socket", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const first = new MockAcpmuxSocket(() => Promise.resolve());
  let release: (() => void) | undefined;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  const daemon = first as unknown as { answer(method: string, params: Record<string, unknown>): Promise<unknown> };
  const answer = daemon.answer.bind(first);
  daemon.answer = async (method, params) => {
    if (method === "_acpmux/events") {
      await pending;
      return answer(method, params);
    }
    return answer(method, params);
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => first as unknown as WebSocket,
  );
  try {
    const exportPromise = client.conversationEvents(() => true);
    const replacement = new MockAcpmuxSocket(() => Promise.resolve());
    (client as unknown as { socket: WebSocket }).socket = replacement as unknown as WebSocket;
    release?.();
    await expect(exportPromise).rejects.toThrow();
  } finally {
    client.close();
  }
});

test("the exporter rejects a missing session envelope and an omitted oversized event", async () => {
  const makeSource = (event: EventRecord) => ({
    detail: async () => ({ lastSeq: 1 }),
    page: async () => ({ events: [event], hasMore: false }),
  });
  const missing = {
    seq: 1,
    at: 1792800000000,
    dir: "mux",
    kind: "user_message",
    msg: { text: "missing envelope" },
  } as EventRecord;
  const omitted: EventRecord = {
    sessionId: "chat-1",
    seq: 1,
    at: 1792800000000,
    dir: "mux",
    kind: "user_message",
    msg: { _meta: { acpmux: { omitted: { bytes: 5, reason: "too_large" } } } },
  };
  const { recordedConversationEvents } = await import("./exportEvents");
  await expect(recordedConversationEvents("chat-1", makeSource(missing), () => true)).rejects.toThrow();
  await expect(recordedConversationEvents("chat-1", makeSource(omitted), () => true)).rejects.toThrow();
});
