// l10n-allow-file: synthetic mock daemon fixtures, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, { had: key in scope, value: scope[key] }]));
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const [key, previous] of saved) {
    if (previous.had) scope[key] = previous.value;
    else delete scope[key];
  }
  dom.window.close();
});

const memory = () => {
  const kept = new Map<string, unknown>();
  return {
    get: async (key: string) => kept.get(key),
    set: async (key: string, value: unknown) => void kept.set(key, value),
    delete: async (key: string) => void kept.delete(key),
  };
};

async function mockClient() {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const relay = new MockAcpmuxSocket(() => Promise.resolve());
  return AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => relay as unknown as WebSocket,
    "daemon",
  );
}

test("mock mode's checkpoint requests reach the in-page daemon, which supports and records checkpoints", async () => {
  const { CheckpointClient } = await import("./client");
  const { CHECKPOINT_CAPABILITY_OP } = await import("./protocol");
  const { mockHost } = await import("../mock");
  const client = await mockClient();
  try {
    const request = (method: string, params: Record<string, unknown>) =>
      client.gitCheckpoint(method as Parameters<typeof client.gitCheckpoint>[0], params);
    let keys = 0;
    const checkpoints = new CheckpointClient(request, {
      persistence: memory(),
      key: () => `key-${++keys}`,
      capabilities: () => request(CHECKPOINT_CAPABILITY_OP, {}) as Promise<{ checkpoints: boolean }>,
    });
    checkpoints.select({ cwd: String(mockHost.cwd ?? "~/code/acpmux"), hostKind: "local" });
    expect(await checkpoints.refreshCapabilities()).toBe(true);

    const empty = await checkpoints.list({ include_candidates: true });
    expect(empty.checkpoints).toEqual([]);
    expect(empty.candidates).toEqual([]);

    const created = await checkpoints.create({
      expected_repository_id: empty.repository_id,
      expected_worktree_id: empty.worktree_id,
      reason: "manual",
    });
    expect(created.replayed).toBe(false);
    expect(created.result.repository_id).toBe(empty.repository_id);
    expect(created.result.complete).toBe(true);

    const listed = await checkpoints.list();
    expect(listed.checkpoints.map((record) => record.checkpoint_id)).toEqual([created.result.checkpoint_id]);
    expect((await checkpoints.get({ idempotency_key: "key-1" })).checkpoint_id).toBe(created.result.checkpoint_id);

    const pinned = await checkpoints.pin({
      checkpoint_id: created.result.checkpoint_id,
      pin_id: "user:1",
      reason: "manual",
    });
    expect(pinned.result.pins).toEqual([{ pin_id: "user:1", reason: "manual" }]);
    expect(Number(pinned.result.revision)).toBeGreaterThan(Number(created.result.revision));
    const released = await checkpoints.unpin({ checkpoint_id: created.result.checkpoint_id, pin_id: "user:1" });
    expect(released.result.pins).toEqual([]);
  } finally {
    client.close();
  }
});

test("the mock replays a create for its idempotency key and names a missing record", async () => {
  const { MockCheckpoints } = await import("./mock");
  const owner = new MockCheckpoints(() => ({ root: "/repo", head: "a".repeat(40), branch: "main", changedFiles: 2 }));
  const first = owner.answer("s", "git.checkpoint.create", { cwd: "/repo", idempotency_key: "k" }) as {
    result: { checkpoint_id: string };
    replayed: boolean;
  };
  const again = owner.answer("s", "git.checkpoint.create", { cwd: "/repo", idempotency_key: "k" }) as typeof first;
  expect(again).toEqual({ ...first, replayed: true });
  expect(() => owner.answer("s", "git.checkpoint.get", { checkpoint_id: "none" })).toThrow("resource.not_found");
  expect(() => owner.answer("s", "git.checkpoint.create", {})).toThrow("validation.invalid");
});

test("a session outside a repository is refused as mockGit refuses it, while support stays host-wide", async () => {
  const { MockCheckpoints } = await import("./mock");
  const owner = new MockCheckpoints(() => {
    throw new Error("Not a git repository");
  });
  expect(owner.answer("s", "git.capabilities", {})).toEqual({ checkpoints: true });
  expect(() => owner.answer("s", "git.checkpoint.list", {})).toThrow("Not a git repository");
});

test("outside mock mode the checkpoint requests stay the native host's", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const posted: { method: string }[] = [];
  (dom.window as unknown as Record<string, unknown>).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: async ({ method }: { method: string }) => {
          posted.push({ method });
          return { ok: true, value: { checkpoints: false } };
        },
      },
    },
  };
  const relay = new MockAcpmuxSocket(() => Promise.resolve());
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => {},
    undefined,
    () => relay as unknown as WebSocket,
    "native",
  );
  try {
    expect(await client.gitCheckpoint("git.capabilities", {})).toEqual({ checkpoints: false });
    expect(posted.map((call) => call.method)).toContain("git.capabilities");
  } finally {
    client.close();
    delete (dom.window as unknown as Record<string, unknown>).webkit;
  }
});
