// l10n-allow-file: transcript provenance fixtures, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";
import type { AcpmuxRow } from "./model";
import type { MessageSource } from "./messageSources";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

test("replayed source events mark the exact reply even after a later turn starts", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as { record: (target: string, step: unknown) => void };
  const source: MessageSource = {
    kind: "file",
    uri: "file:///docs/readme.md",
    title: "readme.md",
    toolCallId: "read-1",
  };
  const steps = [
    { mux: "user_message", msg: { text: "Read the guide" } },
    { mux: "turn_started", msg: { turnId: "t1" } },
    {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The guide says hello." } },
      meta: { acpmux: { segment: "t1.boot.1" } },
    },
    { mux: "turn_end", msg: { turnId: "t1", stopReason: "end_turn" } },
    { mux: "turn_result", msg: { turnId: "t1", status: "completed" } },
    { mux: "user_message", msg: { text: "Thanks" } },
    { mux: "turn_started", msg: { turnId: "t2" } },
    {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Welcome." } },
      meta: { acpmux: { segment: "t2.boot.1" } },
    },
    { mux: "turn_sources", msg: { turnId: "t1", replyId: "t1.boot.1", sources: [source] } },
    { mux: "turn_end", msg: { turnId: "t2", stopReason: "end_turn" } },
    { mux: "turn_result", msg: { turnId: "t2", status: "completed" } },
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: AcpmuxRow[] = [];
  let ready: (() => void) | undefined;
  const heard = new Promise<void>((resolve) => {
    ready = resolve;
  });
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows;
      if (rows.some((row) => row.id === "assistant-t1.boot.1" && row.sources)) ready?.();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    await heard;
    expect(rows.find((row) => row.id === "assistant-t1.boot.1")?.sources).toEqual([source]);
    expect(rows.find((row) => row.id === "assistant-t2.boot.1")?.sources).toBeUndefined();
  } finally {
    client.close?.();
  }
});
