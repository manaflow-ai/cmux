// Quick edits on the Cloud page (a rename, the idle policy) show the new value at once, with no
// "Renaming…" or pending label and nothing held, and a refusal puts the old value back with the
// page's one error line (design/toasts.md: say it once, on the thing it's about).
import { describe, expect, test } from "bun:test";
import { MockCloudProvider } from "./mockProvider";
import { CloudOps } from "./ops";
import { CloudStore } from "./store";

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function started(provider = new MockCloudProvider()) {
  let key = 0;
  const store = new CloudStore(provider, { newKey: () => `key_${++key}` });
  const unsubscribe = store.subscribe(() => undefined);
  await flush();
  await flush();
  return { store, provider, unsubscribe };
}

const row = (store: CloudStore, id: string) => store.getSnapshot().rows.find((r) => r.id === id)!;
/** The idle policy the detail shows: the waiting change's, else the mirror's. */
const idleShown = (store: CloudStore, id: string) => {
  const r = row(store, id);
  return (r.idle !== undefined ? r.idle : r.machine!.idle_policy?.idle_seconds) ?? 0;
};

// The mock answers within the call (its watch event can settle an intent before the call returns),
// so a change the mock refuses is what keeps an intent waiting long enough to look at.

describe("Cloud page quick edits", () => {
  test("a rename shows the new name at once with no pending label", async () => {
    const { store, unsubscribe } = await started();
    const id = store.getSnapshot().rows[0]!.id;
    const done = store.rename(id, "  renamed box ");
    // At once, with no label.
    expect(row(store, id).title).toBe("renamed box");
    expect(row(store, id).pending).toBeUndefined();
    await done;
    await flush();
    expect(row(store, id).title).toBe("renamed box");
    expect(row(store, id).pending).toBeUndefined();
    unsubscribe();
  });

  test("a refused rename puts the old name back and says why once", async () => {
    const { store, provider, unsubscribe } = await started();
    const before = store.getSnapshot().rows[0]!;
    provider.failNext = CloudOps.machineRename;
    const done = store.rename(before.id, "never");
    expect(row(store, before.id).title).toBe("never");
    await done;
    await flush();
    expect(row(store, before.id).title).toBe(before.title);
    expect(row(store, before.id).pending).toBeUndefined();
    expect(store.getSnapshot().error).toBeTruthy();
    unsubscribe();
  });

  test("an idle change shows at once, and a refusal restores the machine's policy", async () => {
    const { store, provider, unsubscribe } = await started();
    const first = store.getSnapshot().rows[0]!;
    const was = idleShown(store, first.id);
    expect(was).not.toBe(3600);

    provider.failNext = CloudOps.machineIdlePolicySet;
    const refused = store.setIdlePolicy(first.id, 3600);
    // Before the refusal arrives: the new value, with no pending label.
    expect(idleShown(store, first.id)).toBe(3600);
    expect(row(store, first.id).pending).toBeUndefined();
    await refused;
    await flush();
    expect(row(store, first.id).idle).toBeUndefined();
    expect(idleShown(store, first.id)).toBe(was);
    expect(store.getSnapshot().error).toBeTruthy();

    await store.setIdlePolicy(first.id, null);
    await flush();
    expect(idleShown(store, first.id)).toBe(0);
    unsubscribe();
  });

  test("a slow change (pause) still shows its pending label", async () => {
    const { store, provider, unsubscribe } = await started();
    const running = store.getSnapshot().rows.find((r) => r.status === "running")!;
    provider.failNext = CloudOps.machinePause;
    const done = store.pause(running.id);
    expect(row(store, running.id).pending).toBe("pause");
    await done;
    unsubscribe();
  });
});
