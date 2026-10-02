import { describe, expect, test } from "bun:test";
import { CHECKPOINT_OPS, type Checkpoint, type CheckpointList } from "./protocol";
import { CheckpointClient, type CheckpointPersistence, type CheckpointTarget } from "./client";

const target: CheckpointTarget = { cwd: "/repo", sessionId: "session-1" };
const checkpoint: Checkpoint = {
  checkpoint_id: "cp-1",
  repository_id: "repo-1",
  worktree_id: "worktree-1",
  ref: "refs/cmux/checkpoints/worktree-1/cp-1",
  object_id: "0123456789abcdef0123456789abcdef01234567",
  revision: "1",
  complete: true,
  skipped: [],
  skipped_total: 0,
  created_at: "2026-10-02T00:00:00.000Z",
  expires_at: null,
  base: { head: null, branch: null, detached: true },
  coverage: { included: 1, omitted: 0, unavailable: 0 },
  included: { tracked: 1, untracked: 0, staged_entries: 0 },
  bytes: { logical: 2, newly_stored: 2 },
  limits: { max_bytes: 100, max_files: 10, max_untracked_file_bytes: 10000000 },
  pins: [],
};
const list: CheckpointList = {
  repository_id: "repo-1",
  worktree_id: "worktree-1",
  checkpoints: [],
  next_cursor: null,
  candidates: [{ path: "draft.txt", bytes: 5, eligible: true }],
  limits: { max_bytes: 100, max_files: 10, max_untracked_file_bytes: 10000000 },
};

class MemoryPersistence implements CheckpointPersistence {
  values = new Map<string, unknown>();
  async get(key: string) {
    return this.values.get(key);
  }
  async set(key: string, value: unknown) {
    this.values.set(key, value);
  }
  async delete(key: string) {
    this.values.delete(key);
  }
}

type Call = { method: string; params: Record<string, unknown> };
function harness() {
  const calls: Call[] = [];
  let failCreate = true;
  const request = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params: structuredClone(params) });
    if (method === CHECKPOINT_OPS.list) return list;
    if (method === CHECKPOINT_OPS.get) {
      if (params.idempotency_key) throw Object.assign(new Error("missing"), { code: "resource.not_found" });
      return checkpoint;
    }
    if (method === CHECKPOINT_OPS.create) {
      if (failCreate) {
        failCreate = false;
        throw new Error("connection lost");
      }
      return { result: checkpoint, revision: "2", replayed: false };
    }
    return { result: checkpoint, revision: "3", replayed: false };
  };
  return { calls, request };
}

describe("CheckpointClient", () => {
  test("sends only cwd and contract parameters to the native Git owner", async () => {
    const h = harness();
    const client = new CheckpointClient(
      h.request,
      new MemoryPersistence(),
      () => "wire-key",
      async () => ({
        checkpoints: true,
      }),
    );
    await client.refreshCapabilities();
    client.select({ ...target, hostKind: "local" });
    await client.list({ include_candidates: true });
    await client.get({ checkpoint_id: "cp-1" });
    await client.pin({ checkpoint_id: "cp-1", pin_id: "user:keep", reason: "Keep" });
    await client.unpin({ checkpoint_id: "cp-1", pin_id: "user:keep" });
    expect(h.calls).toEqual([
      { method: CHECKPOINT_OPS.list, params: { cwd: "/repo", include_candidates: true } },
      { method: CHECKPOINT_OPS.get, params: { cwd: "/repo", checkpoint_id: "cp-1" } },
      {
        method: CHECKPOINT_OPS.pin,
        params: {
          cwd: "/repo",
          checkpoint_id: "cp-1",
          pin_id: "user:keep",
          reason: "Keep",
          idempotency_key: "wire-key",
        },
      },
      {
        method: CHECKPOINT_OPS.unpin,
        params: { cwd: "/repo", checkpoint_id: "cp-1", pin_id: "user:keep", idempotency_key: "wire-key" },
      },
    ]);
  });

  test("lists candidates through the selected cwd and drops a stale reply after switching", async () => {
    const gate = Promise.withResolvers<CheckpointList>();
    const persistence = new MemoryPersistence();
    const request = async (method: string, params: Record<string, unknown>) => {
      if (method === CHECKPOINT_OPS.list && params.cwd === "/old") return gate.promise;
      return list;
    };
    const client = new CheckpointClient(request, persistence, undefined, async () => ({ checkpoints: true }));
    await client.refreshCapabilities();
    client.select({ cwd: "/old" });
    const pending = client.list({ include_candidates: true });
    client.select({ cwd: "/new" });
    await client.list({ include_candidates: true });
    gate.resolve({ ...list, repository_id: "old" });
    await pending;
    expect(client.state.list?.repository_id).toBe("repo-1");
  });

  test("persists a create key, gets first after uncertainty, then retries with the same key", async () => {
    const h = harness();
    const persistence = new MemoryPersistence();
    const client = new CheckpointClient(
      h.request,
      persistence,
      () => "create-key",
      async () => ({ checkpoints: true }),
    );
    await client.refreshCapabilities();
    client.select(target);
    await expect(client.create({ include_untracked: ["draft.txt"] })).rejects.toThrow("connection lost");
    const firstCreate = h.calls.find((call) => call.method === CHECKPOINT_OPS.create)!;
    expect(firstCreate.params.idempotency_key).toBe("create-key");
    const receipt = await client.create({ include_untracked: ["draft.txt"] });
    expect(receipt.result.checkpoint_id).toBe("cp-1");
    expect(h.calls.map((call) => call.method)).toEqual([
      CHECKPOINT_OPS.create,
      CHECKPOINT_OPS.get,
      CHECKPOINT_OPS.create,
    ]);
    expect(h.calls[2]?.params.idempotency_key).toBe("create-key");
  });

  test("replays a found create to preserve the session ledger revision", async () => {
    const persistence = new MemoryPersistence();
    const calls: Call[] = [];
    let first = true;
    const request = async (method: string, params: Record<string, unknown>) => {
      calls.push({ method, params: structuredClone(params) });
      if (method === CHECKPOINT_OPS.create && first) {
        first = false;
        throw { code: "native.timed_out", origin: "native" };
      }
      if (method === CHECKPOINT_OPS.get)
        return { ...checkpoint, revision: "41" };
      return { result: { ...checkpoint, revision: "42" }, revision: "99", replayed: true };
    };
    const client = new CheckpointClient(request, persistence, () => "create-key", async () => ({ checkpoints: true }));
    client.select(target);
    await client.refreshCapabilities();
    await expect(client.create({ include_untracked: ["draft.txt"] })).rejects.toMatchObject({
      code: "native.timed_out",
    });

    const receipt = await client.create({ include_untracked: ["draft.txt"] });
    expect(receipt.revision).toBe("99");
    expect(receipt.result.revision).toBe("42");
    expect(calls.map((call) => call.method)).toEqual([
      CHECKPOINT_OPS.create,
      CHECKPOINT_OPS.get,
      CHECKPOINT_OPS.create,
    ]);
    expect(calls[1]?.params).toEqual({ cwd: "/repo", idempotency_key: "create-key" });
    expect(calls[2]?.params).toEqual({
      cwd: "/repo",
      include_untracked: ["draft.txt"],
      idempotency_key: "create-key",
    });
  });

  test("reads the native capability once and gates actions when it is absent", async () => {
    const client = new CheckpointClient(
      async () => list,
      new MemoryPersistence(),
      undefined,
      async () => ({ checkpoints: false }),
    );
    client.select(target);
    expect(await client.refreshCapabilities()).toBe(false);
    await expect(client.list()).rejects.toMatchObject({ code: "operation.unsupported" });
  });

  test("does not send a request for managed pin removal", async () => {
    const h = harness();
    const client = new CheckpointClient(h.request, new MemoryPersistence(), undefined, async () => ({
      checkpoints: true,
    }));
    await client.refreshCapabilities();
    client.select(target);
    await expect(client.unpin({ checkpoint_id: "cp-1", pin_id: "handoff:cp-1" })).rejects.toMatchObject({
      code: "operation.failed",
      reason: "managed_pin",
    });
    expect(h.calls).toHaveLength(0);
  });

  test("refuses mutations while offline and does not queue them", async () => {
    const h = harness();
    const client = new CheckpointClient(h.request, new MemoryPersistence(), undefined, async () => ({
      checkpoints: true,
    }));
    await client.refreshCapabilities();
    client.select(target);
    client.setOnline(false);
    await expect(client.create({})).rejects.toMatchObject({ code: "operation.failed", reason: "offline" });
    expect(h.calls).toHaveLength(0);
  });
});
