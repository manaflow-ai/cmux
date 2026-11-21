// A start the selection overtook while its `session/new` was out (issue 44964): what the drop may end
// and what it must give back. Only a session this request made fresh is ended; an adopt resumes the
// person's own conversation and is never killed. A New Tab start the person left gives the pane's
// one-shot startup picks back, and a folder continuation the pane left ends the session it started.
import { expect, test } from "bun:test";
import { FolderContinuation } from "../src/agent-session/acpmux/folderContinuation";

type Hooks = { answer(method: string, params: any): Promise<unknown> };

async function heldClient(holdMethod: string, host: Record<string, unknown> = {}) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const { mockSessions } = await import("../src/agent-session/acpmux/mockFixture");
  const asked: { method: string; params: any }[] = [];
  let hold = false;
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  class Held extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        asked.push({ method, params });
        if (method === holdMethod && hold) await held;
        return answer(method, params);
      };
    }
  }
  const client = (await AcpmuxDirectClient.connect(
    { ...mockHost, ...host },
    () => undefined,
    undefined,
    () => new Held() as unknown as WebSocket,
  )) as any;
  const settle = async (done: () => boolean) => {
    // timeout: the mock daemon answers in microtasks; past 2 s a wait names what it waited on, not a hang.
    const deadline = performance.now() + 2_000;
    while (!done()) {
      if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  };
  return {
    client,
    asked,
    other: mockSessions[1]!.sessionId,
    holdNext: () => (hold = true),
    release: () => release(),
    settle,
  };
}

test("an adopt the selection overtook is never killed", async () => {
  const f = await heldClient("session/new");
  try {
    f.holdNext();
    const adopting = f.client.resume({ harness: "claude", sessionId: "outside-1" }).catch(() => undefined);
    await f.settle(() => f.asked.some((ask) => ask.method === "session/new"));
    await f.client.select(f.other);
    f.release();
    await adopting;
    expect(f.asked.some((ask) => ask.method === "_acpmux/kill")).toBe(false);
  } finally {
    f.release();
    f.client.close();
  }
});

test("a new chat start the person left gives the pane's startup picks back", async () => {
  const f = await heldClient("session/new", { harness: "codex", model: "gpt-5" });
  try {
    f.holdNext();
    const starting = f.client.create();
    await f.settle(() => f.asked.some((ask) => ask.method === "session/new"));
    await f.client.select(f.other);
    f.release();
    expect(await starting).toBeUndefined();
    // The started session is ended, and the next new chat still starts on the picks.
    expect(f.asked.some((ask) => ask.method === "_acpmux/kill")).toBe(true);
    expect(f.client.host.harness).toBe("codex");
    expect(f.client.host.model).toBe("gpt-5");
  } finally {
    f.release();
    f.client.close();
  }
});

test("a folder continuation the pane left ends the session it started", async () => {
  const discarded: string[] = [];
  let current = true;
  await new FolderContinuation().run({
    start: async () => {
      current = false;
      return "started";
    },
    current: () => current,
    copyText: () => undefined,
    select: async () => true,
    clearFolder: () => undefined,
    discard: (id) => void discarded.push(id),
  });
  expect(discarded).toEqual(["started"]);
});
