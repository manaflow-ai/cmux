// A message the person types is always theirs, queued behind a running turn or sent as a steer
// (Leo, 2026-10-21: a typed steer came back "Not sent: it needs your own key press or click").
// The host counts one gesture at a time and checks a prompt's frame only when it gets to it, so
// two sends before the first was checked left the second with none. Each send now binds its own
// gesture to its promptId at once (`transport.gesture`), and the frame carries that ticket.
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

type Sent = { promptId?: string; ticket?: string; steer?: boolean };

/// The pane with the host's `transport.gesture`: each reserve gets a ticket named for its promptId
/// (`reserves` lists them in order); `gesture` false: the host has none to give (posted input).
async function pane(gesture = true, pause = () => Promise.resolve()) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const reserves: string[] = [];
  const window = dom.window as unknown as Record<string, unknown>;
  window.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string; params: { intent?: { params?: { promptId?: string } } } }) => {
          const promptId = message.params.intent?.params?.promptId;
          if (message.method !== "transport.gesture" || !promptId) return { ok: false, error: { code: "unsupported" } };
          reserves.push(promptId);
          return gesture
            ? { ok: true, value: { ticket: `ticket-${promptId}` } }
            : { ok: false, error: { code: "transport.gesture_required" } };
        },
      },
    },
  };
  const sent: Sent[] = [];
  class Relay extends MockAcpmuxSocket {
    constructor() {
      super(pause);
      const self = this as unknown as { answer: (method: string, params: Record<string, any>) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = (method, params) => {
        if (method === "session/prompt")
          sent.push({
            promptId: params._meta?.acpmux?.promptId,
            ticket: params._meta?.cmuxGesture,
            steer: params._meta?.acpmux?.steer === true,
          });
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
  const close = () => {
    client.close?.();
    delete window.webkit;
  };
  return { client, sent, reserves, close };
}

test("a prompt queued behind the turn and a steer each go with their own gesture", async () => {
  const { client, sent, reserves, close } = await pane();
  try {
    // The first prompt runs; the second is typed behind it; the third steers into the turn.
    await Promise.all([
      client.send("Run the tests", [], "p-first"),
      client.send("Then fix the flaky one", [], "p-queued"),
      client.send("Keep the old flag", [], "p-steer", undefined, undefined, true),
    ]);
    // Each reserved at its own send, before anything else (the person's key press is fresh then).
    expect(reserves).toEqual(["p-first", "p-queued", "p-steer"]);
    expect(sent).toHaveLength(3);
    expect(sent).toContainEqual({ promptId: "p-first", ticket: "ticket-p-first", steer: false });
    expect(sent).toContainEqual({ promptId: "p-queued", ticket: "ticket-p-queued", steer: false });
    expect(sent).toContainEqual({ promptId: "p-steer", ticket: "ticket-p-steer", steer: true });
  } finally {
    close();
  }
});

test("a prompt with a kept ticket goes with it, and one with no gesture goes with none", async () => {
  const { client, sent, reserves, close } = await pane(false);
  try {
    // A prompt held for the folder trust answer brings the ticket its send kept (heldPrompt.ts).
    await client.send("Add a remove command", [], "p-held", undefined, "kept-ticket");
    // Input that is not the person's: the host gives no ticket, and decides the frame as before.
    await client.send("Posted by a script", [], "p-posted");
    expect(reserves).toEqual(["p-posted"]);
    expect(sent).toEqual([
      { promptId: "p-held", ticket: "kept-ticket", steer: false },
      { promptId: "p-posted", ticket: undefined, steer: false },
    ]);
  } finally {
    close();
  }
});

test("a send that waits before it goes binds its gesture at once", async () => {
  const { client, sent, reserves, close } = await pane();
  try {
    // App.tsx's send waits for the chat's start and its persistence before `client.send`, and the
    // composer is free meanwhile: each Enter binds its own gesture before any of that.
    const first = client.bindSendGesture("p-first");
    const second = client.bindSendGesture("p-second");
    expect(reserves).toEqual(["p-first", "p-second"]);
    expect(sent).toEqual([]);
    await Promise.all([
      client.send("Run the tests", [], first!.promptId, undefined, first!.ticket),
      client.send("Keep the old flag", [], second!.promptId, undefined, second!.ticket, true),
    ]);
    // The pending tickets ride their own prompts; nothing else was reserved.
    expect(reserves).toEqual(["p-first", "p-second"]);
    expect(sent).toContainEqual({ promptId: "p-first", ticket: "ticket-p-first", steer: false });
    expect(sent).toContainEqual({ promptId: "p-second", ticket: "ticket-p-second", steer: true });
  } finally {
    close();
  }
});

test("page handoff waits for a queued prompt's ticket and daemon acceptance", async () => {
  const turnGate = Promise.withResolvers<void>();
  const { client, sent, close } = await pane(true, () => turnGate.promise);
  const firstTaken = Promise.withResolvers<void>();
  const ticket = Promise.withResolvers<string>();
  const queuedTaken = Promise.withResolvers<void>();
  const released = Promise.withResolvers<void>();
  let handedOff = 0;
  const first = client.send("Keep working", [], "running", undefined, "first-ticket", false, firstTaken.resolve);
  try {
    await firstTaken.promise;
    const queued = client.send("Then run tests", [], "queued", released.resolve, ticket.promise, false, () => {
      handedOff += 1;
      queuedTaken.resolve();
    });
    // The local queue frees the composer before the transport can take this prompt.
    await released.promise;
    expect(sent.map((prompt) => prompt.promptId)).toEqual(["running"]);
    expect(handedOff).toBe(0);
    ticket.resolve("queued-ticket");
    await queuedTaken.promise;
    expect(sent).toContainEqual({ promptId: "queued", ticket: "queued-ticket", steer: false });
    expect(handedOff).toBe(1);
    turnGate.resolve();
    await Promise.all([first, queued]);
    // A later RPC response must not hand the page off a second time.
    expect(handedOff).toBe(1);
  } finally {
    turnGate.resolve();
    ticket.resolve("queued-ticket");
    close();
  }
});
