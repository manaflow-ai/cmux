// Return on a working agent sends at once (https://github.com/manaflow-ai/cmux/issues/56544: "why doesn't it
// just automatically send when i press enter, why do i need to see this send now?"). The person's
// steer goes with `_meta.acpmux.steerNow`, the flag a queued prompt's Send now carries: acpmux stops
// only the agent's current step, so the agent reads it now and the turn runs on. Its bubble is
// marked sent now from the send on, so it never offers Send now. A prompt that queues (⌘Return, or
// Follow-Up Messages set to Queue) carries neither flag and stops nothing.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Sent = { promptId?: string; steer: boolean; steerNow: boolean; interrupt: boolean };

async function pane() {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const sent: Sent[] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt") {
          const meta = params._meta?.acpmux ?? {};
          sent.push({
            promptId: meta.promptId,
            steer: meta.steer === true,
            steerNow: meta.steerNow === true,
            interrupt: meta.interrupt === true,
          });
        }
        return answer(method, params);
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new Relay() as unknown as WebSocket,
  );
  return { client, sent, close: () => client.close?.() };
}

test("Return's steer is read now; a queued prompt is not", async () => {
  const steers = await import("./conversation/pendingSteerModel");
  const { client, sent, close } = await pane();
  try {
    await Promise.all([
      client.send("Run the tests", [], "p-turn"),
      client.send("Then fix the flaky one", [], "p-queued"),
      client.send("Use the staging database", [], "p-steer", undefined, undefined, true),
    ]);
    expect(sent).toContainEqual({ promptId: "p-turn", steer: false, steerNow: false, interrupt: false });
    // ⌘Return (or Follow-Up Messages: Queue) waits behind the turn and stops nothing.
    expect(sent).toContainEqual({ promptId: "p-queued", steer: false, steerNow: false, interrupt: false });
    // Return steers it in now: only the agent's step stops (steerNow), never the turn (interrupt).
    expect(sent).toContainEqual({ promptId: "p-steer", steer: true, steerNow: true, interrupt: false });
  } finally {
    close();
  }
  // Its bubble never offers Send now; the queued prompt keeps its own queue row's Send now.
  // `sentNowState` is replaced on each change: read the module's live binding.
  expect(steers.sentNowState.ids.has("p-steer")).toBe(true);
  expect(steers.sentNowState.ids.has("p-queued")).toBe(false);
  expect(steers.sentNowState.ids.has("p-turn")).toBe(false);
});
