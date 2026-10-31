// Manual Freestyle regression: bun test tests/manual/apps-registry-lifetime.test.ts
// Kept outside webviews' CI discovery; exercise the registry's late replies directly.
import { describe, expect, test } from "bun:test";
import { MockAppsProvider, sampleApps, sampleLocalApp, sampleRegistry } from "../../webviews/src/pages/apps/mockProvider";
import { AppsStore } from "../../webviews/src/pages/apps/store";
import { RegistryOps } from "../../webviews/src/pages/apps/types";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((yes) => { resolve = yes; });
  return { promise, resolve };
}

function setup() {
  const data = { ...sampleApps(), registry: sampleRegistry() };
  data.installed["local/notes-pane"] = sampleLocalApp();
  const provider = new MockAppsProvider(data);
  return { provider, store: new AppsStore(provider) };
}

function hold(provider: MockAppsProvider, operation: string, fails = false) {
  const entered = deferred();
  const reply = deferred();
  const original = provider.call.bind(provider);
  let held = false;
  provider.call = async <R>(op: string, params: unknown): Promise<R> => {
    const result = await original<R>(op, params);
    if (op === operation && !held) {
      held = true;
      entered.resolve();
      await reply.promise;
      if (fails) throw new Error("late registry error");
    }
    return result;
  };
  return { entered, reply };
}

describe("App Store registry lifetime", () => {
  for (const op of [RegistryOps.me, RegistryOps.listings, RegistryOps.submissions, RegistryOps.reviewQueue]) {
    for (const fails of [false, true]) {
      test(`${op} ${fails ? "failure" : "success"} after stop publishes nothing`, async () => {
        const { provider, store } = setup();
        const gate = hold(provider, op, fails);
        const start = store.start();
        await gate.entered.promise;
        store.stop();
        const snapshot = store.getSnapshot();
        const calls = provider.calls.length;
        gate.reply.resolve();
        await start;
        expect(store.getSnapshot()).toBe(snapshot);
        expect(provider.calls.length).toBe(calls);
      });
    }
  }

  test("an old start cannot replace a restarted store's registry", async () => {
    const { provider, store } = setup();
    const gate = hold(provider, RegistryOps.me);
    const oldStart = store.start();
    await gate.entered.promise;
    store.stop();
    await store.start();
    const snapshot = store.getSnapshot();
    gate.reply.resolve();
    await oldStart;
    expect(store.getSnapshot()).toBe(snapshot);
    store.stop();
  });

  const actions = [
    { op: RegistryOps.get, run: (store: AppsStore) => store.getListing("sample-studio/workspace-board", "0.2.0") },
    { op: RegistryOps.submit, run: (store: AppsStore) => store.submit("local/notes-pane", "sample-studio", "") },
    { op: RegistryOps.reviewDecide, run: (store: AppsStore) => store.decide("sub_9", "approve", "") },
    { op: RegistryOps.reviewFile, run: (store: AppsStore) => store.openReviewFile("sub_9", "web/clock.js") },
  ];
  for (const action of actions) {
    for (const fails of [false, true]) {
      test(`${action.op} ${fails ? "failure" : "success"} after stop cannot publish or start follow-up work`, async () => {
        const { provider, store } = setup();
        await store.start();
        const gate = hold(provider, action.op, fails);
        const pending = action.run(store);
        await gate.entered.promise;
        store.stop();
        const snapshot = store.getSnapshot();
        const calls = provider.calls.length;
        gate.reply.resolve();
        await pending;
        expect(store.getSnapshot()).toBe(snapshot);
        expect(provider.calls.length).toBe(calls);
      });
    }
  }
});
