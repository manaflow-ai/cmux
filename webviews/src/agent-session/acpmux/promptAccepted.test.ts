// A prompt sent while the agent's turn runs never sticks in the composer. The composer holds a
// prompt until acpmux takes it (`accepted`), and Enter and Send do nothing while it holds one, so a
// missed acceptance left the typed prompt in the field with Return and Send dead for the rest of
// the turn (Leo, 2026-10-20: a lane chat with its agent mid-turn could not send at all). The
// pane's own `queued` record can be missed (a lagged event stream drops records); two signals do
// not depend on it: the queue row the pane draws itself, and acpmux's `_acpmux/prompt_accepted`,
// which goes straight to the sending connection.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

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
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

const settle = async (done: () => boolean) => {
  for (let tries = 0; tries < 500 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

type Hooks = { answer: (method: string, params: any) => Promise<unknown>; emit: (target: string, step: any) => void };

test("a prompt behind a running turn is taken once it shows in the queue, without the queued record", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // The turn never ends, and the event stream loses acpmux's `queued` record.
  class LaggingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => new Promise<void>(() => undefined));
      const hooks = this as unknown as Hooks;
      const emit = hooks.emit.bind(this);
      hooks.emit = (target, step) => {
        if (step?.mux !== "queued") emit(target, step);
      };
    }
  }
  let snapshot: { queue: { id: string; prompt: string }[]; isWorking?: boolean } = { queue: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as typeof snapshot),
    undefined,
    () => new LaggingHost() as unknown as WebSocket,
  );
  try {
    void client.send("start the work").catch(() => undefined);
    await settle(() => Boolean(snapshot.isWorking));
    let accepted = false;
    void client.send("and then this", [], undefined, () => (accepted = true)).catch(() => undefined);
    await settle(() => accepted);
    expect(snapshot.queue.map((entry) => entry.prompt)).toEqual(["and then this"]);
    expect(accepted).toBe(true);
  } finally {
    client.close?.();
  }
});

test("acpmux's prompt_accepted takes the prompt when no record reaches the pane", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  // session/prompt answers only at the turn's end (never here) and records nothing the pane sees;
  // acpmux tells the sending connection it took the prompt.
  class QuietHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks & { deliver: (message: unknown) => void };
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        hooks.deliver({
          jsonrpc: "2.0",
          method: "_acpmux/prompt_accepted",
          params: { sessionId: params.sessionId, promptId: params._meta?.acpmux?.promptId, turnId: "t", queued: false },
        });
        return new Promise(() => undefined);
      };
    }
  }
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => new QuietHost() as unknown as WebSocket,
  );
  try {
    let accepted = false;
    void client.send("ship it", [], undefined, () => (accepted = true)).catch(() => undefined);
    await settle(() => accepted);
    expect(accepted).toBe(true);
  } finally {
    client.close?.();
  }
});
