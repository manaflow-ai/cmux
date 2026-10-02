import { expect, test } from "bun:test";
import { CheckpointClient } from "./client";
import { checkpoint, list, target, MemoryPersistence } from "./testFixture";

test("capabilities are fail closed until the native connection answers", () => {
  const client = new CheckpointClient(async () => list);
  expect(client.getSnapshot().supported).toBe(false);
});

test("an indeterminate owner mutation keeps the original key across client reload", async () => {
  const persistence = new MemoryPersistence();
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  let attempt = 0;
  const request = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    if (method.endsWith(".get")) throw { code: "resource.not_found", origin: "session_host" };
    if (++attempt === 1)
      throw { code: "mutation.indeterminate", origin: "session_host", userMessage: "Recover the capture" };
    return { result: checkpoint, revision: "1", replayed: true };
  };
  const first = new CheckpointClient(request, {
    persistence,
    capabilities: async () => ({ checkpoints: true }),
    key: () => "first",
  });
  first.select(target);
  await first.refreshCapabilities();
  await expect(first.create()).rejects.toMatchObject({ code: "mutation.indeterminate" });
  const reloaded = new CheckpointClient(request, {
    persistence,
    capabilities: async () => ({ checkpoints: true }),
    key: () => "second",
  });
  reloaded.select(target);
  await reloaded.refreshCapabilities();
  await reloaded.create();
  expect(calls.map((call) => call.method)).toEqual([
    "git.checkpoint.create",
    "git.checkpoint.get",
    "git.checkpoint.create",
  ]);
  expect(calls.at(-1)?.params.idempotency_key).toBe("first");
});

test("double activation sends one mutation even while persistence is awaiting", async () => {
  const gate = Promise.withResolvers<unknown>();
  const calls: string[] = [];
  const client = new CheckpointClient(
    async (method) => {
      calls.push(method);
      return gate.promise;
    },
    { capabilities: async () => ({ checkpoints: true }), persistence: new MemoryPersistence() },
  );
  client.select(target);
  await client.refreshCapabilities();
  const first = client.create();
  const second = client.create().catch((error) => error);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(calls).toHaveLength(1);
  gate.resolve({ result: checkpoint, revision: "1", replayed: false });
  await first;
  await second;
});

test("a late capture key read cannot send after selecting another session", async () => {
  const gate = Promise.withResolvers<unknown>();
  const calls: string[] = [];
  const client = new CheckpointClient(
    async (method) => {
      calls.push(method);
      return checkpoint;
    },
    {
      capabilities: async () => ({ checkpoints: true }),
      persistence: { get: async () => gate.promise, set: async () => {}, delete: async () => {} },
    },
  );
  client.select(target);
  await client.refreshCapabilities();
  const pending = client.create().catch((error) => error);
  client.select({ cwd: "/other", sessionId: "other" });
  gate.resolve(undefined);
  await pending;
  expect(calls).toHaveLength(0);
});

test("reconciled receipt replays the create and preserves the ledger revision", async () => {
  const persistence = new MemoryPersistence();
  let calls = 0;
  let lost = true;
  const client = new CheckpointClient(
    async (method) => {
      if (method.endsWith(".create")) {
        calls++;
        if (lost) {
          lost = false;
          throw { code: "native.timed_out", origin: "native" };
        }
      }
      if (method.endsWith(".get")) return { ...checkpoint, revision: "7" };
      return { result: { ...checkpoint, revision: "8" }, revision: "12", replayed: true };
    },
    { persistence, capabilities: async () => ({ checkpoints: true }) },
  );
  client.select(target);
  await client.refreshCapabilities();
  await expect(client.create()).rejects.toMatchObject({ code: "native.timed_out" });
  let observed: string | undefined;
  client.subscribe(() => {
    observed = client.getSnapshot().record?.checkpoint_id;
  });
  await client.create();
  expect(calls).toBe(2);
  expect(observed).toBe(checkpoint.checkpoint_id);
  expect(client.getSnapshot().record?.revision).toBe("8");
});

test("unresolved capture prevents a changed selection from creating another checkpoint", async () => {
  let calls = 0;
  const client = new CheckpointClient(
    async () => {
      calls++;
      throw { code: "native.timed_out", origin: "native" };
    },
    { capabilities: async () => ({ checkpoints: true }), persistence: new MemoryPersistence() },
  );
  client.select(target);
  await client.refreshCapabilities();
  await expect(client.create({ include_untracked: ["draft.txt"] })).rejects.toThrow();
  await expect(client.create({ include_untracked: [] })).rejects.toMatchObject({ code: "idempotency.conflict" });
  expect(calls).toBe(1);
});
