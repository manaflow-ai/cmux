// Move to Terminal (terminalMoveRow.ts) shows only for a chat whose summary names the harness's own
// session id: the published snapshot summary must carry acpmux's `agentSessionId`, or the row never
// shows for a real chat (review of #41845: the projection dropped it).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await teardownDom(saved, { window: dom.window });
});

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 500 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Hooks = { sessions: Record<string, unknown>[] };
type Snapshot = { sessionId?: string; summary?: { agentSessionId?: string } };

const agentSessionId = "11111111-2222-3333-4444-555555555555";

test("the shown chat's summary carries the harness session id Move to Terminal resumes", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { newSessionSummary } = await import("../mockFixture");
  class WithHarnessSession extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      hooks.sessions.push({ ...newSessionSummary("chat-1", "~/code/cmux", Date.now()), agentSessionId });
    }
  }
  let snapshot: Snapshot = {};
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, sessionId: "chat-1" },
    (next) => (snapshot = next as Snapshot),
    undefined,
    () => new WithHarnessSession() as unknown as WebSocket,
  );
  try {
    await settle(() => snapshot.sessionId === "chat-1" && snapshot.summary?.agentSessionId !== undefined);
    expect(snapshot.sessionId).toBe("chat-1");
    expect(snapshot.summary?.agentSessionId).toBe(agentSessionId);
  } finally {
    client.close?.();
  }
});
