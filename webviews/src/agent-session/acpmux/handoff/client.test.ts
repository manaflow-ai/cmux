import { describe, expect, test } from "bun:test";
import { AcpmuxRpcError, HANDOFF_OPS, type Handoff, type HandoffSession } from "./protocol";
import { HandoffClient } from "./client";
import type { HandoffReviewInput } from "./review";

type Call = { method: string; params: Record<string, unknown> };

const sourceSession: HandoffSession = {
  sessionId: "session-source",
  harness: "claude",
  cwd: "/tmp/handoff-fixture",
  coverage: [{ item: "transcript", status: "included", detail: null }],
  enforcement: { policy: "native policy", label: "native_policy", isolation: "unverified", detail: null },
};
const targetSession: HandoffSession = {
  ...sourceSession,
  sessionId: "session-target",
  harness: "codex",
};

function record(overrides: Partial<Handoff> = {}): Handoff {
  return {
    handoffId: "handoff-1",
    handoffKey: "prepare-key-1",
    state: "draft",
    revision: 1,
    source: { ...sourceSession, seq: 12 },
    target: targetSession,
    capsule: {
      text: "Continue from the reviewed checkpoint.",
      maxBytes: 64 * 1024,
      context: { fromSeq: 0, toSeq: 12, truncated: false, bytes: 38, totalBytes: 38 },
      checkpoint: null,
      memoryRefs: [],
    },
    promptId: null,
    turnId: null,
    createdAt: "2026-10-02T00:00:00.000Z",
    updatedAt: "2026-10-02T00:00:00.000Z",
    ...overrides,
  };
}

const review: HandoffReviewInput = {
  capsule: "Continue from the reviewed checkpoint.",
  checkpoint: { reference: "git:abc123", confirmed: true },
  approvedMemoryReferences: [],
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function harness(initial: Handoff | null = record()) {
  const calls: Call[] = [];
  let current = initial;
  let implementation = async (method: string, params: Record<string, unknown>): Promise<any> => {
    calls.push({ method, params: structuredClone(params) });
    if (method === HANDOFF_OPS.get) return current;
    if (method === HANDOFF_OPS.prepare) {
      current = current ?? record({ handoffKey: String(params.handoffKey) });
      return current;
    }
    if (method === HANDOFF_OPS.draft) {
      current = { ...current!, revision: current!.revision + 1, capsule: { ...current!.capsule, text: String((params.capsule as any).text) } };
      return current;
    }
    if (method === HANDOFF_OPS.start) {
      current = { ...current!, state: "started", revision: current!.revision + 1, promptId: String(params.promptId) };
      return { handoffId: current.handoffId, targetSessionId: current.target.sessionId, promptId: String(params.promptId), turnId: "turn-1", outcome: "started" };
    }
    if (method === HANDOFF_OPS.discard) return { discarded: true };
    throw new Error(`unexpected ${method}`);
  };
  const request = async (method: string, params: Record<string, unknown>): Promise<any> => implementation(method, params);
  return {
    calls,
    request,
    setRequest(next: (method: string, params: Record<string, unknown>) => Promise<any>) { implementation = next; },
    get current() { return current; },
    set current(value: Handoff | null) { current = value; },
  };
}

async function selectedClient(h = harness()) {
  const client = new HandoffClient(h.request, () => {}, () => "stable-client-key");
  client.select((h.current ?? record()).source.sessionId);
  await client.refresh();
  return { client, h };
}

describe("HandoffClient", () => {
  test("coalesces duplicate prepare calls and reuses one handoff key", async () => {
    const h = harness(null);
    const gate = deferred<Handoff>();
    let prepares = 0;
    h.setRequest(async (method, params) => {
      h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.get) return null;
      if (method === HANDOFF_OPS.prepare) {
        prepares += 1;
        await gate.promise;
        return record({ handoffKey: String(params.handoffKey) });
      }
      throw new Error(`unexpected ${method}`);
    });
    const client = new HandoffClient(h.request, () => {}, () => "stable-client-key");
    client.select(sourceSession.sessionId);
    await client.refresh();
    const first = client.prepare(targetSession.harness);
    const second = client.prepare(targetSession.harness);
    gate.resolve(record({ handoffKey: "stable-client-key" }));
    const [a, b] = await Promise.all([first, second]);
    expect(prepares).toBe(1);
    expect(a?.handoffKey).toBe("stable-client-key");
    expect(b?.handoffKey).toBe("stable-client-key");
    expect(h.calls.filter((call) => call.method === HANDOFF_OPS.prepare)[0]?.params).toEqual({
      sessionId: sourceSession.sessionId,
      harness: targetSession.harness,
      handoffKey: "stable-client-key",
    });
  });

  test("does not send a prompt before start, and uses the daemon prompt key at start", async () => {
    const { client, h } = await selectedClient(harness(null));
    await client.prepare(targetSession.harness);
    expect(h.calls.some((call) => call.method === HANDOFF_OPS.start)).toBe(false);
    await client.save(review);
    expect(h.calls.some((call) => call.method === HANDOFF_OPS.start)).toBe(false);
    client.select(targetSession.sessionId);
    await client.refresh();
    await client.start(review);
    const start = h.calls.find((call) => call.method === HANDOFF_OPS.start);
    expect(start?.params.promptId).toBe("handoff-1");
    expect(start?.params).toMatchObject({ handoffId: "handoff-1", promptId: "handoff-1", checkpoint: { ref: "git:abc123", attest: true } });
  });

  test("replays a lost draft acknowledgement after get with exactly the same write key", async () => {
    const h = await selectedClient();
    const original = h.h.calls.length;
    const draftParams: Record<string, unknown>[] = [];
    let first = true;
    h.h.setRequest(async (method, params) => {
      h.h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.draft) {
        draftParams.push(structuredClone(params));
        if (first) { first = false; throw new Error("connection lost"); }
        return h.h.current;
      }
      if (method === HANDOFF_OPS.get) return h.h.current;
      throw new Error(`unexpected ${method}`);
    });
    await h.client.save(review);
    expect(h.h.calls.length).toBeGreaterThan(original);
    expect(draftParams).toHaveLength(2);
    expect(draftParams[1]).toEqual(draftParams[0]);
    expect(h.h.calls.slice(-2).map((call) => call.method)).toEqual([HANDOFF_OPS.get, HANDOFF_OPS.draft]);
  });

  test("refuses an unconfirmed checkpoint before making a start RPC", async () => {
    const { client, h } = await selectedClient();
    client.select(targetSession.sessionId);
    await client.refresh();
    await expect(client.start({ ...review, checkpoint: { reference: "git:abc123", confirmed: false } })).rejects.toThrow();
    expect(h.calls.some((call) => call.method === HANDOFF_OPS.start)).toBe(false);
  });

  test("selection changes prevent stale refresh and mutation completions from being adopted", async () => {
    const first = deferred<Handoff>();
    const h = harness(null);
    h.setRequest(async (method, params) => {
      h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.get && params.sessionId === sourceSession.sessionId) return first.promise;
      if (method === HANDOFF_OPS.get) return null;
      throw new Error(`unexpected ${method}`);
    });
    const client = new HandoffClient(h.request, () => {});
    client.select(sourceSession.sessionId);
    const refresh = client.refresh();
    client.select(targetSession.sessionId);
    await client.refresh();
    expect(client.state.ready).toBe(true);
    first.resolve(record());
    await refresh;
    expect(client.state.record).toBeUndefined();
    expect(client.state.ready).toBe(true);
  });

  test("replays a lost start acknowledgement with the same prompt and revision", async () => {
    const { client, h } = await selectedClient();
    client.select(targetSession.sessionId);
    await client.refresh();
    const startParams: Record<string, unknown>[] = [];
    let attempts = 0;
    h.setRequest(async (method, params) => {
      h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.start) {
        attempts += 1;
        startParams.push(structuredClone(params));
        if (attempts === 1) throw new Error("connection lost");
        return { handoffId: "handoff-1", targetSessionId: targetSession.sessionId, promptId: String(params.promptId), turnId: "turn-1", outcome: "already_started" };
      }
      if (method === HANDOFF_OPS.get) return h.current;
      throw new Error(`unexpected ${method}`);
    });
    const receipt = await client.start(review);
    expect(receipt?.outcome).toBe("already_started");
    expect(startParams).toHaveLength(2);
    expect(startParams[1]).toEqual(startParams[0]);
    expect(startParams[0]?.promptId).toBe("handoff-1");
    expect(h.calls.map((call) => call.method).filter((method) => method === HANDOFF_OPS.start)).toHaveLength(2);
  });

  test("coalesces duplicate start calls into one daemon request", async () => {
    const { client, h } = await selectedClient();
    client.select(targetSession.sessionId);
    await client.refresh();
    const gate = deferred<any>();
    let starts = 0;
    h.setRequest(async (method, params) => {
      h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.start) {
        starts += 1;
        return gate.promise;
      }
      if (method === HANDOFF_OPS.get) return h.current;
      throw new Error(`unexpected ${method}`);
    });
    const first = client.start(review);
    const second = client.start(review);
    await Promise.resolve();
    expect(starts).toBe(1);
    gate.resolve({ handoffId: "handoff-1", targetSessionId: targetSession.sessionId, promptId: "handoff-1", turnId: "turn-1", outcome: "started" });
    const [a, b] = await Promise.all([first, second]);
    expect(a).toEqual(b);
    expect(starts).toBe(1);
  });

  test("surfaces stale revision as a conflict and blocks a later start", async () => {
    const { client, h } = await selectedClient();
    client.select(targetSession.sessionId);
    await client.refresh();
    h.setRequest(async (method, params) => {
      h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.draft) throw new AcpmuxRpcError({ message: "stale", data: { reason: "stale_revision" } });
      if (method === HANDOFF_OPS.get) return h.current;
      throw new Error(`unexpected ${method}`);
    });
    await expect(client.save(review)).rejects.toThrow("stale");
    expect(client.state.conflict).toBe(true);
    await expect(client.start(review)).resolves.toBeUndefined();
    expect(h.calls.some((call) => call.method === HANDOFF_OPS.start)).toBe(false);
  });

  test("requires reconnect refresh before retrying mutations", async () => {
    const { client, h } = await selectedClient();
    client.disconnect();
    expect(client.state.ready).toBe(false);
    await expect(client.prepare(targetSession.harness)).resolves.toBeUndefined();
    expect(h.calls.some((call) => call.method === HANDOFF_OPS.prepare)).toBe(false);
    await client.refresh();
    expect(client.state.ready).toBe(true);
    await expect(client.prepare(targetSession.harness)).resolves.toBeDefined();
  });

  test("keeps the draft visible and records an error when discard fails", async () => {
    const { client, h } = await selectedClient();
    h.setRequest(async (method, params) => {
      h.calls.push({ method, params: structuredClone(params) });
      if (method === HANDOFF_OPS.discard) throw new Error("discard unavailable");
      if (method === HANDOFF_OPS.get) return h.current;
      throw new Error(`unexpected ${method}`);
    });
    await expect(client.discard()).rejects.toThrow("discard unavailable");
    expect(client.state.record?.handoffId).toBe("handoff-1");
    expect(client.state.error).toBe("discard unavailable");
    expect(client.state.busy).toBeUndefined();
    expect(client.state.ready).toBe(true);
  });
});

test("queued local edits advance only through this client's accepted revisions", async () => {
  const { client, h } = await selectedClient();
  const first = client.save({ ...review, capsule: "first edit", revision: 1 });
  const second = client.save({ ...review, capsule: "second edit", revision: 1 });
  await Promise.all([first, second]);
  expect(h.calls.filter((c) => c.method === HANDOFF_OPS.draft).map((c) => c.params.revision)).toEqual([1, 2]);
  expect(client.state.record?.capsule.text).toBe("second edit");
});
