// A question's answer goes with the person's gesture ticket for its pick, as an option pick does:
// the host signs an answer for another machine's agent daemon only with that ticket (cx-0q7o), so
// an answer sent without one was refused there and the question card failed with "approve this
// on the Mac app".
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};
const gestures: unknown[] = [];

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  // The host's message handler: a ticket for every transport.gesture, nothing for the rest.
  (dom.window as unknown as Record<string, unknown>).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string; params: { intent?: unknown } }) => {
          if (message.method !== "transport.gesture") return { ok: true, value: {} };
          gestures.push(message.params.intent);
          return { ok: true, value: { ticket: "ticket-1" } };
        },
      },
    },
  };
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

test("a question's answer carries the person's ticket for its session, prompt and option", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  class RecordingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const host = this as unknown as { answer: (method: string, params: Record<string, unknown>) => Promise<unknown> };
      const answer = host.answer.bind(this);
      host.answer = (method, params) => {
        sent.push({ method, params });
        return answer(method, params);
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new RecordingHost() as unknown as WebSocket,
  );
  try {
    const notes = { "Which one?": { preview: "[ B ]", notes: "but narrower" } };
    await client.permission("perm-1", "allow_once", { "Which one?": "B" }, "sess-1", notes);
    // The ticket is for exactly these answers and annotations (the host compares them).
    expect(gestures).toEqual([
      {
        method: "_acpmux/permission_respond",
        params: {
          sessionId: "sess-1",
          permissionId: "perm-1",
          optionId: "allow_once",
          answers: { "Which one?": "B" },
          annotations: notes,
        },
      },
    ]);
    const respond = sent.find((frame) => frame.method === "_acpmux/permission_respond");
    expect(respond?.params).toEqual({
      sessionId: "sess-1",
      permissionId: "perm-1",
      optionId: "allow_once",
      answers: { "Which one?": "B" },
      annotations: notes,
      _meta: { cmuxGesture: "ticket-1" },
    });
  } finally {
    client.close?.();
  }
});
