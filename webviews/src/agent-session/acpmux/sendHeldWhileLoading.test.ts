// A prompt sent while acpmux is still loading (the bridge has no acpmux yet, or acpmux does not
// answer in time) was failed at once, and its row said to restart (ask-5174ba0b6d, Leo 2026-11-06:
// "your sends are getting busted intermittently as things load"). Now the pane sends it again under
// the same prompt id once acpmux answers; the row waits ("Sending when ready") and never fails.
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

type Row = { id: string; kind: string; text?: string; failed?: boolean; delivery?: Record<string, unknown> };

test("a prompt acpmux times out on while it loads is sent again under its id and never fails", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  type Hooks = { answer: (method: string, params: any) => Promise<unknown> };
  const prompts: string[] = [];
  let secondAsk!: () => void;
  const askedTwice = new Promise<void>((resolve) => (secondAsk = resolve));
  class LoadingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        prompts.push(String(params?._meta?.acpmux?.promptId));
        if (prompts.length === 2) secondAsk();
        // The first two asks land while acpmux is still loading.
        if (prompts.length <= 2)
          return Promise.reject(
            Object.assign(new Error("acpmux did not answer in time"), { code: "native.timed_out" }),
          );
        return answer(method, params);
      };
    }
  }
  let rows: Row[] = [];
  const states: Record<string, unknown>[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      const row = rows.find((candidate) => candidate.kind === "user" && candidate.text === "ship it");
      if (row?.delivery) states.push({ ...row.delivery, failed: row.failed === true });
    },
    undefined,
    () => new LoadingHost() as unknown as WebSocket,
  );
  let accepted = 0;
  try {
    const sent = client
      .send("ship it", [], "held-prompt", () => (accepted += 1))
      .then(
        () => undefined,
        (error: unknown) => error,
      );
    // Before the fix the first refusal failed the send at once.
    await Promise.race([askedTwice, sent]);
    expect(prompts.length).toBe(2);
    // Held: the composer keeps it and the row waits, quietly.
    expect(accepted).toBe(0);
    expect(await sent).toBeUndefined();
    expect(accepted).toBe(1);
    expect(prompts).toEqual(["held-prompt", "held-prompt", "held-prompt"]);
    expect(states.some((state) => state.waitingForHost === true)).toBe(true);
    expect(states.some((state) => state.failed === true || state.state === "failed")).toBe(false);
    const row = rows.find((candidate) => candidate.kind === "user" && candidate.text === "ship it");
    expect(row?.failed).not.toBe(true);
    expect(row?.delivery?.waitingForHost).toBeUndefined();
  } finally {
    client.close?.();
  }
});

test("a prompt that waits out the host's deadline stays as a failed row with Retry, never gone", async () => {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const { translate } = await import("./i18n");
  type Hooks = { answer: (method: string, params: any) => Promise<unknown> };
  let asks = 0;
  class StuckHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        asks += 1;
        return Promise.reject(Object.assign(new Error("acpmux did not answer in time"), { code: "native.timed_out" }));
      };
    }
  }
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { hostWaitMs: 600 });
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new StuckHost() as unknown as WebSocket,
  );
  try {
    const error = (await client.send("ship it", [], "stuck-prompt").catch((caught: unknown) => caught)) as {
      failedRow?: string;
    };
    expect(asks).toBeGreaterThan(1);
    expect(error.failedRow).toBe("local-stuck-prompt");
    const row = rows.find((candidate) => candidate.id === "local-stuck-prompt") as Row & { error?: string };
    expect(row?.failed).toBe(true);
    expect(row?.error).toBe(translate("prompt.failure.hostAway"));
    expect(row?.error).not.toMatch(/restart/i);
  } finally {
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
});
