// Each prompt the pane sends carries where it is on its way (plans/cmux-next/composer-delivery-DESIGN.md):
// sending, then delivered once acpmux took it, read once the agent started on it, or failed with the
// hop it stopped at. A send with no answer says so and then fails, Retry sends the same prompt id
// again (acpmux runs a prompt id once), and a late acceptance still lands. Every prompt's
// `_meta.acpmux` holds only keys the host lets through (policy.json `known_params`): Retry once
// sent `resend`, which only the host may set, and the host refused every Retry.
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";

/// The `_meta.acpmux` keys the cmux host's pane policy lets through on `session/prompt`.
const policyPath = path.resolve(import.meta.dir, "../../../../cmux-tui/crates/cmux-agent-pane-policy/policy.json");
const allowedPromptMeta: string[] = JSON.parse(readFileSync(policyPath, "utf8")).known_params["session/prompt"].acpmux;

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

/// Yields until `done()` holds; fails after 2 s.
const settle = async (done: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!done()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

type Row = {
  id: string;
  kind: string;
  text?: string;
  failed?: boolean;
  delivery?: { state: string; promptId: string; slow?: boolean; hop?: string; code?: string; acceptedAt?: number };
};
type Hooks = {
  answer: (method: string, params: any) => Promise<unknown>;
  deliver: (message: unknown) => void;
};

test("a prompt goes from sending to delivered to read", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const seen = new Set<string>();
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const row of rows) if (row.text === "ship it" && row.delivery) seen.add(row.delivery.state);
    },
    undefined,
    () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
  );
  try {
    await client.send("ship it");
    const sent = rows.find((row) => row.kind === "user" && row.text === "ship it");
    expect(sent?.delivery?.state).toBe("read");
    expect(seen.has("sending")).toBe(true);
  } finally {
    client.close?.();
  }
});

test("a send with no answer says it is still sending, fails, and Retry sends the same prompt id again", async () => {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20, failMs: 80 });
  const prompts: any[] = [];
  let hooks: Hooks | undefined;
  class SilentHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) => {
        if (method !== "session/prompt") return answer(method, params);
        prompts.push(params);
        return new Promise(() => undefined);
      };
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new SilentHost() as unknown as WebSocket,
  );
  const mine = () => rows.find((row) => row.kind === "user" && row.text === "anyone there");
  try {
    void client.send("anyone there").catch(() => undefined);
    await settle(() => mine()?.delivery?.slow === true);
    expect(mine()?.delivery?.state).toBe("sending");
    await settle(() => mine()?.failed === true);
    expect(mine()?.delivery).toMatchObject({ state: "failed", hop: "acpmux", code: "timeout" });
    const promptId = mine()!.delivery!.promptId;
    void client.retryPrompt(mine()!.id).catch(() => undefined);
    await settle(() => prompts.length === 2);
    expect(prompts[1]._meta.acpmux.promptId).toBe(promptId);
    // The host refuses a page prompt with a key outside its policy (transport.intent_invalid).
    for (const prompt of prompts) {
      const unknown = Object.keys(prompt._meta.acpmux).filter((key) => !allowedPromptMeta.includes(key));
      expect(unknown).toEqual([]);
    }
    // acpmux takes it late: the row is delivered, not failed.
    hooks!.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/prompt_accepted",
      params: { sessionId: prompts[1].sessionId, promptId, turnId: "t", queued: false },
    });
    await settle(() => mine()?.delivery?.state === "delivered");
    expect(mine()?.failed).toBeFalsy();
  } finally {
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
});

test("a refused send stays as its failed row, naming the hop, for Retry, Edit or Remove", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class RefusingHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) =>
        method === "session/prompt"
          ? Promise.reject(Object.assign(new Error("the sandbox refused it"), { code: "sandbox.denied" }))
          : answer(method, params);
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new RefusingHost() as unknown as WebSocket,
  );
  try {
    const error = await client.send("rm -rf build").catch((refusal: unknown) => refusal);
    const row = rows.find((entry) => entry.kind === "user" && entry.text === "rm -rf build");
    expect(row?.failed).toBe(true);
    expect(row?.delivery).toMatchObject({ state: "failed", hop: "acpmux" });
    expect((error as { failedRow?: string }).failedRow).toBe(row!.id);
    expect(client.takeFailedPrompt(row!.id)).toEqual({ input: "rm -rf build", attachments: [] });
    expect(rows.some((entry) => entry.id === row!.id)).toBe(false);
  } finally {
    client.close?.();
  }
});

test("a prompt the connection dropped before acpmux took it goes back to its sender, not to a row", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class SilentHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) =>
        method === "session/prompt" ? new Promise(() => undefined) : answer(method, params);
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new SilentHost() as unknown as WebSocket,
  );
  const sent = client.send("before the drop").catch((refusal: unknown) => refusal);
  await settle(() => rows.some((row) => row.text === "before the drop"));
  client.close?.();
  const error = await sent;
  expect((error as { failedRow?: string }).failedRow).toBeUndefined();
  expect(rows.some((row) => row.text === "before the drop" && row.failed)).toBe(false);
});

test("a sender that still holds its prompt gets no second copy as a failed row", async () => {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  class SilentHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) =>
        method === "session/prompt" ? new Promise(() => undefined) : answer(method, params);
    }
  }
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => new SilentHost() as unknown as WebSocket,
  );
  // The delivery deadlines on a fake clock: the test runs past the fail deadline without waiting it out.
  jest.useFakeTimers();
  try {
    void client.send("held here", [], undefined, () => undefined).catch(() => undefined);
    const mine = () => rows.find((row) => row.text === "held here");
    jest.advanceTimersByTime(deliveryTiming.slowMs);
    expect(mine()?.delivery?.slow).toBe(true);
    jest.advanceTimersByTime(deliveryTiming.failMs - deliveryTiming.slowMs);
    expect(mine()?.failed).toBeFalsy();
    expect(mine()?.delivery?.state).toBe("sending");
  } finally {
    jest.useRealTimers();
    client.close?.();
  }
});
