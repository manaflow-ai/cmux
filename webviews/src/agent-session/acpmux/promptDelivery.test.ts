// Each prompt the pane sends carries where it is on its way (plans/cmux-next/composer-delivery-DESIGN.md):
// sending, then delivered once acpmux took it, read once the agent started on it, or failed with the
// hop it stopped at. A send with no answer stays pending well past a slow acknowledgement (longer on
// this Mac's acpmux, whose native relay journals it), then fails with Retry under the same prompt
// id, and a late acceptance still lands. Every prompt's
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
  promptId?: string;
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

test("the optimistic prompt keeps its row key and position through the echo and turn start", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  type ManualHooks = Hooks & { emit: (target: string, step: unknown) => void };
  class ManualHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as ManualHooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = (method, params) =>
        method === "session/prompt" ? new Promise(() => undefined) : answer(method, params);
    }
  }
  let snapshot: { rows: Row[]; isWorking?: boolean } = { rows: [] };
  const host = new ManualHost();
  const hooks = host as unknown as ManualHooks;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as typeof snapshot),
    undefined,
    () => host as unknown as WebSocket,
  );
  const promptId = "stable-prompt";
  try {
    void client.send("ship it", [], promptId).catch(() => undefined);
    await settle(() => snapshot.rows.some((row) => row.id === `local-${promptId}`));
    const optimisticIndex = snapshot.rows.findIndex((row) => row.id === `local-${promptId}`);
    const optimistic = snapshot.rows[optimisticIndex];
    expect(optimisticIndex).toBeGreaterThanOrEqual(0);

    hooks.emit(mockHost.sessionId!, {
      mux: "user_message",
      msg: { text: "ship it", promptId, turnId: "turn-1" },
    });
    await settle(() => snapshot.rows.some((row) => row.promptId === promptId && row.delivery?.state === "read"));
    const echoedIndex = snapshot.rows.findIndex((row) => row.promptId === promptId);
    const echoed = snapshot.rows[echoedIndex];
    expect(echoed?.id).toBe(optimistic?.id);
    expect(echoedIndex).toBe(optimisticIndex);

    hooks.emit(mockHost.sessionId!, { mux: "turn_started", msg: { turnId: "turn-1" } });
    await settle(() => snapshot.isWorking === true);
    const startedIndex = snapshot.rows.findIndex((row) => row.promptId === promptId);
    expect(snapshot.rows[startedIndex]?.id).toBe(optimistic?.id);
    expect(startedIndex).toBe(optimisticIndex);
  } finally {
    client.close?.();
  }
});

test("a slow acknowledgement stays pending past the former failure deadline and accepts a late ack", async () => {
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
    // fixed-wait: proving the row does not fail means outwaiting the remote deadline (failMs) once.
    await new Promise((resolve) => setTimeout(resolve, deliveryTiming.failMs + 20));
    expect(mine()?.failed).toBeFalsy();
    expect(mine()?.delivery?.state).toBe("sending");
    expect(client.swapHold()).toBe("composer.send-untaken");
    expect(prompts.length).toBe(1);
    const promptId = mine()!.delivery!.promptId;
    // The host refuses a page prompt with a key outside its policy (transport.intent_invalid).
    for (const prompt of prompts) {
      const unknown = Object.keys(prompt._meta.acpmux).filter((key) => !allowedPromptMeta.includes(key));
      expect(unknown).toEqual([]);
    }
    // acpmux takes it late: the row is delivered, not failed.
    hooks!.deliver({
      jsonrpc: "2.0",
      method: "_acpmux/prompt_accepted",
      params: { sessionId: prompts[0].sessionId, promptId, turnId: "t", queued: false },
    });
    await settle(() => mine()?.delivery?.state === "delivered");
    expect(mine()?.failed).toBeFalsy();
  } finally {
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
});

test("a remote-origin send with no answer still fails after the deadline, for Retry", async () => {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20, failMs: 80 });
  const prompts: any[] = [];
  class SilentRemoteHost extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      const hooks = this as unknown as Hooks;
      const answer = hooks.answer.bind(this);
      hooks.answer = async (method, params) => {
        if (method === "initialize") {
          // A connection with no native relay journal behind it (another machine's acpmux).
          const result = (await answer(method, params)) as { _meta: { acpmux: Record<string, unknown> } };
          return { ...result, _meta: { ...result._meta, acpmux: { ...result._meta.acpmux, origin: "remote" } } };
        }
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
    () => new SilentRemoteHost() as unknown as WebSocket,
  );
  const mine = () => rows.find((row) => row.kind === "user" && row.text === "anyone there");
  try {
    void client.send("anyone there").catch(() => undefined);
    await settle(() => mine()?.failed === true);
    expect(mine()?.delivery).toMatchObject({ state: "failed", hop: "acpmux", code: "timeout" });
    expect(prompts.length).toBe(1);
  } finally {
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
});

test("a local send nobody answers stays sending past the remote deadline, then fails for Retry", async () => {
  // The host's journal may not keep a prompt (over its size cap, evicted, no journal at all), and
  // the page cannot see that: a local send still fails, only later than a remote one.
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20, failMs: 80, localFailMs: 240 });
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const hooks = socket as unknown as Hooks;
  const answer = hooks.answer.bind(socket);
  const prompts: any[] = [];
  hooks.answer = (method, params) => {
    if (method !== "session/prompt") return answer(method, params);
    prompts.push(params);
    return new Promise(() => undefined);
  };
  let rows: Row[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => (rows = snapshot.rows as Row[]),
    undefined,
    () => socket as unknown as WebSocket,
  );
  const mine = () => rows.find((row) => row.kind === "user" && row.text === "too big to journal");
  try {
    void client.send("too big to journal").catch(() => undefined);
    // fixed-wait: proving the row does not fail at the remote deadline means outwaiting it once.
    await new Promise((resolve) => setTimeout(resolve, deliveryTiming.failMs + 20));
    expect(mine()?.failed).toBeFalsy();
    expect(mine()?.delivery?.state).toBe("sending");
    await settle(() => mine()?.failed === true);
    expect(mine()?.delivery).toMatchObject({ state: "failed", hop: "acpmux", code: "timeout" });
    expect(prompts.length).toBe(1);
  } finally {
    Object.assign(deliveryTiming, timing);
    client.close?.();
  }
});

test("a busy session keeps an unacknowledged eight-image prompt queued with previews", async () => {
  const { AcpmuxDirectClient, deliveryTiming } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const timing = { ...deliveryTiming };
  Object.assign(deliveryTiming, { slowMs: 20, failMs: 80 });
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const hooks = socket as unknown as Hooks & { emit(target: string, step: unknown): void };
  const answer = hooks.answer.bind(socket);
  const prompts: any[] = [];
  hooks.answer = (method, params) => {
    if (method !== "session/prompt") return answer(method, params);
    prompts.push(params);
    return new Promise(() => undefined);
  };
  let snapshot: { rows: Row[]; isWorking?: boolean; queue?: Array<{ id: string; images?: unknown[] }> } = { rows: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as typeof snapshot),
    undefined,
    () => socket as unknown as WebSocket,
  );
  const attachments = Array.from({ length: 8 }, (_, n) => ({
    id: `shot-${n}`,
    kind: "image" as const,
    name: `shot-${n}.png`,
    mimeType: "image/png",
    size: 3,
    data: "YWJj",
  }));
  try {
    hooks.emit(mockHost.sessionId!, { mux: "turn_started", msg: {} });
    await settle(() => snapshot.isWorking === true);
    void client.send("keep all screenshots", attachments, "slow-busy").catch(() => undefined);
    await settle(() => snapshot.queue?.some((entry) => entry.id === "slow-busy") === true);
    // fixed-wait: proving the row does not fail means outwaiting the remote deadline (failMs) once.
    await new Promise((resolve) => setTimeout(resolve, deliveryTiming.failMs + 40));
    expect(snapshot.rows.some((row) => row.failed)).toBe(false);
    expect(snapshot.queue?.find((entry) => entry.id === "slow-busy")?.images).toHaveLength(8);
    expect(prompts).toHaveLength(1);
    expect(prompts[0].prompt.filter((block: { type: string }) => block.type === "image")).toHaveLength(8);
    expect(prompts[0]._meta.acpmux.promptId).toBe("slow-busy");
    expect(client.swapHold()).toBe("composer.send-untaken");
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
