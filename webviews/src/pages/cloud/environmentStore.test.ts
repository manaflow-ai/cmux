import { describe, expect, test } from "bun:test";
import { EnvironmentStore } from "./environmentStore";
import {
  environmentDraft,
  environmentPatch,
  SETUP_SCRIPT_BYTES,
  type CloudEnvironment,
  type EnvironmentClient,
  type EnvironmentPatch,
} from "./environmentModel";

function environment(overrides: Partial<CloudEnvironment> = {}): CloudEnvironment {
  return {
    id: "env_personal",
    scope: "personal",
    name: "Default",
    is_default: true,
    setup_script: null,
    env_vars: [{ name: "NODE_ENV", value: "development" }],
    secrets: [{ name: "PACKAGE_TOKEN", updated_at: "2026-11-01T00:00:00Z" }],
    network: { mode: "limited", package_managers: true, domains: [] },
    created_at: "2026-11-01T00:00:00Z",
    updated_at: "2026-11-01T00:00:00Z",
    updated_by: "user_example",
    ...overrides,
  };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
function fake(overrides: Partial<EnvironmentClient> = {}) {
  const writes: { id: string; patch: EnvironmentPatch }[] = [];
  const client: EnvironmentClient = {
    list: async () => [environment()],
    get: async (id) => environment({ id }),
    update: async (id, patch) => {
      writes.push({ id, patch });
      return environment({ id, ...patch });
    },
    derive: async () => ({ setup: { script: "#!/bin/bash\nnpm ci\n" } }),
    ...overrides,
  };
  return { store: new EnvironmentStore(client), writes, client };
}

const settle = async () => {
  for (let i = 0; i < 8; i++) await Promise.resolve();
};

describe("cloud environment editing", () => {
  test("Default resolves the personal scope even when a team Default is first", async () => {
    const { store } = fake({ list: async () => [environment({ id: "env_team", scope: "team" }), environment()] });
    await store.open();
    expect(store.getSnapshot().original?.id).toBe("env_personal");
  });

  test("a missing Default is recoverable without inventing an environment", async () => {
    let attempts = 0;
    const { store } = fake({ list: async () => (++attempts === 1 ? [] : [environment()]) });
    await store.open();
    expect(store.getSnapshot()).toMatchObject({ error: "missing", loading: false });
    await store.retry();
    expect(store.getSnapshot().original?.id).toBe("env_personal");
  });

  test("Default name stays out of PATCH; unchanged fields stay out too", () => {
    const original = environment();
    const draft = environmentDraft(original);
    draft.name = "Renamed";
    draft.script = "echo ready";
    expect(environmentPatch(original, draft)).toEqual({ setup_script: "echo ready" });
    expect(original.setup_script).toBeNull();
  });

  test("domain lines are trimmed, deduplicated and empty lines omitted", () => {
    const original = environment();
    const draft = environmentDraft(original);
    draft.network.domains = [" registry.example.org ", "", "registry.example.org", "  ", "github.com"];
    expect(environmentPatch(original, draft)).toEqual({
      network: { mode: "limited", package_managers: true, domains: ["registry.example.org", "github.com"] },
    });
  });

  test("cancel writes nothing and reopening never restores a typed secret", async () => {
    const { store, writes } = fake();
    await store.open();
    expect(store.getSnapshot().draft?.secrets).toEqual([{ name: "PACKAGE_TOKEN", value: "" }]);
    store.edit({ secrets: [{ name: "PACKAGE_TOKEN", value: "test-write-only-value" }], script: "echo unsaved" });
    store.close();
    expect(store.getSnapshot().draft).toBeUndefined();
    expect(writes).toEqual([]);
    await store.open();
    expect(store.getSnapshot().draft?.secrets).toEqual([{ name: "PACKAGE_TOKEN", value: "" }]);
    expect(store.getSnapshot().draft?.script).toBeNull();
  });

  test("save sends only secret additions/removals and clears the draft", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ secrets: [{ name: "NEW_TOKEN", value: "test-write-only-value" }] });
    await store.save();
    expect(writes).toEqual([
      {
        id: "env_personal",
        patch: {
          set_secrets: [{ name: "NEW_TOKEN", value: "test-write-only-value" }],
          remove_secrets: ["PACKAGE_TOKEN"],
        },
      },
    ]);
    expect(store.getSnapshot()).toMatchObject({ open: false, saving: false });
    expect(store.getSnapshot().draft).toBeUndefined();
  });

  test("existing blank secret is kept; a new blank secret prevents save", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ script: "echo ready" });
    await store.save();
    expect(writes[0]?.patch).toEqual({ setup_script: "echo ready" });
    await store.open();
    store.edit({ secrets: [{ name: "NEW_TOKEN", value: "" }] });
    await store.save();
    expect(store.getSnapshot().error).toBe("secret");
    expect(writes).toHaveLength(1);
  });

  test("failed save retains edits for one successful retry", async () => {
    const writes: EnvironmentPatch[] = [];
    const { store } = fake({
      update: async (_id, patch) => {
        writes.push(patch);
        if (writes.length === 1) throw new Error("temporary platform failure");
        return environment();
      },
    });
    await store.open();
    store.edit({ script: "echo retry", secrets: [{ name: "PACKAGE_TOKEN", value: "test-secret" }] });
    await store.save();
    expect(store.getSnapshot()).toMatchObject({ open: true, saving: false, error: "save" });
    expect(store.getSnapshot().draft?.script).toBe("echo retry");
    await store.save();
    expect(writes).toHaveLength(2);
    expect(writes[1]).toEqual(writes[0]);
    expect(store.getSnapshot().draft).toBeUndefined();
  });

  test("duplicate save, edits and dismissal cannot race an in-flight write", async () => {
    const pending = deferred<CloudEnvironment>();
    let writes = 0;
    const { store } = fake({
      update: async () => {
        writes++;
        return pending.promise;
      },
    });
    await store.open();
    store.edit({ script: "echo first" });
    const first = store.save();
    await store.save();
    store.edit({ script: "echo second" });
    store.close();
    expect(writes).toBe(1);
    expect(store.getSnapshot()).toMatchObject({ open: true, saving: true });
    expect(store.getSnapshot().draft?.script).toBe("echo first");
    pending.resolve(environment());
    await first;
    expect(store.getSnapshot().open).toBe(false);
  });

  test("stale load cannot replace a newer environment or reopen a cancelled sheet", async () => {
    const old = deferred<CloudEnvironment>();
    const { store } = fake({ get: async (id) => (id === "env_old" ? old.promise : environment({ id })) });
    const opening = store.open({ environmentId: "env_old" });
    await store.open({ environmentId: "env_new", section: "script" });
    old.resolve(environment({ id: "env_old" }));
    await opening;
    expect(store.getSnapshot().original?.id).toBe("env_new");
    expect(store.getSnapshot().section).toBe("script");
    const waiting = deferred<CloudEnvironment[]>();
    const cancelled = fake({ list: () => waiting.promise }).store;
    const load = cancelled.open();
    cancelled.close();
    waiting.resolve([environment()]);
    await load;
    expect(cancelled.getSnapshot().open).toBe(false);
    expect(cancelled.getSnapshot().draft).toBeUndefined();
  });

  test("derived prefill remains automatic and a late derivation never replaces typing", async () => {
    const pending = deferred<{ setup: { script: string } }>();
    const calls: unknown[] = [];
    const { store, writes } = fake({
      derive: (options) => {
        calls.push(options);
        return pending.promise;
      },
    });
    await store.open({ repo: "example/project", ref: "main", section: "script" });
    store.edit({ script: "echo mine" });
    pending.resolve({ setup: { script: "echo derived" } });
    await settle();
    expect(calls).toEqual([{ repo: "example/project", ref: "main", environment: "env_personal" }]);
    expect(store.getSnapshot().derivedScript).toBe("echo derived");
    expect(store.getSnapshot().draft?.script).toBe("echo mine");
    store.edit({ script: null, variables: [{ name: "NODE_ENV", value: "test" }] });
    await store.save();
    expect(writes[0]?.patch).toEqual({ env_vars: [{ name: "NODE_ENV", value: "test" }] });
  });

  test("late derived response cannot leak into a different sheet", async () => {
    const pending = deferred<{ setup: { script: string } }>();
    const { store } = fake({ derive: () => pending.promise });
    await store.open({ repo: "example/old" });
    store.close();
    await store.open({ environmentId: "env_new" });
    pending.resolve({ setup: { script: "echo old repository" } });
    await settle();
    expect(store.getSnapshot().derivedScript).toBeUndefined();
  });

  test("script limit measures UTF-8 bytes for both typing and file contents", async () => {
    const { store, writes } = fake();
    await store.open();
    store.edit({ script: "é".repeat(SETUP_SCRIPT_BYTES / 2) });
    await store.save();
    expect(writes).toHaveLength(1);
    await store.open();
    store.edit({ script: "é".repeat(SETUP_SCRIPT_BYTES / 2 + 1) });
    await store.save();
    expect(store.getSnapshot().error).toBe("script");
    expect(writes).toHaveLength(1);
    store.edit({ script: "echo keep" });
    await store.importScript({ size: 1, text: async () => "é".repeat(SETUP_SCRIPT_BYTES / 2 + 1) });
    expect(store.getSnapshot().error).toBe("script");
    expect(store.getSnapshot().draft?.script).toBe("echo keep");
    let reads = 0;
    await store.importScript({
      size: SETUP_SCRIPT_BYTES + 1,
      text: async () => {
        reads++;
        return "";
      },
    });
    expect(reads).toBe(0);
  });

  test("a late file read preserves later typing and never affects a reopened sheet", async () => {
    const { store } = fake();
    await store.open();
    const pending = deferred<string>();
    const reading = store.importScript({ size: 20, text: () => pending.promise });
    store.edit({ script: "echo typed" });
    pending.resolve("echo file");
    await reading;
    expect(store.getSnapshot().draft?.script).toBe("echo typed");
    const old = deferred<string>();
    const oldRead = store.importScript({ size: 20, text: () => old.promise });
    store.close();
    await store.open();
    old.resolve("echo old file");
    await oldRead;
    expect(store.getSnapshot().draft?.script).toBeNull();
  });

  test("duplicate and malformed variable names are refused without a write", async () => {
    const { store, writes } = fake();
    await store.open();
    for (const variables of [
      [{ name: "1INVALID", value: "test" }],
      [
        { name: "NAME", value: "a" },
        { name: "NAME", value: "b" },
      ],
    ]) {
      store.edit({ variables });
      await store.save();
      expect(store.getSnapshot().error).toBe("names");
    }
    expect(writes).toHaveLength(0);
  });
});

test("the last chosen setup file wins even if an earlier file finishes first", async () => {
  const { store } = fake();
  await store.open();
  const first = deferred<string>();
  const second = deferred<string>();
  const firstRead = store.importScript({ size: 20, text: () => first.promise });
  const secondRead = store.importScript({ size: 20, text: () => second.promise });
  first.resolve("echo first file");
  await firstRead;
  second.resolve("echo second file");
  await secondRead;
  expect(store.getSnapshot().draft?.script).toBe("echo second file");
});

test("choosing an oversized file invalidates an earlier pending file read", async () => {
  const { store } = fake();
  await store.open();
  store.edit({ script: "echo keep" });
  const first = deferred<string>();
  const firstRead = store.importScript({ size: 20, text: () => first.promise });
  let oversizedReads = 0;
  await store.importScript({
    size: SETUP_SCRIPT_BYTES + 1,
    text: async () => {
      oversizedReads++;
      return "echo oversized";
    },
  });
  first.resolve("echo old selection");
  await firstRead;
  expect(oversizedReads).toBe(0);
  expect(store.getSnapshot().error).toBe("script");
  expect(store.getSnapshot().draft?.script).toBe("echo keep");
});

test("editing away and back to the same text still invalidates a pending file read", async () => {
  const { store } = fake();
  await store.open();
  store.edit({ script: "echo original" });
  const pending = deferred<string>();
  const reading = store.importScript({ size: 20, text: () => pending.promise });
  store.edit({ script: "echo changed" });
  store.edit({ script: "echo original" });
  pending.resolve("echo selected file");
  await reading;
  expect(store.getSnapshot().draft?.script).toBe("echo original");
});
