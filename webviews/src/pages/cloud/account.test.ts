// The account side on the cmux.wire/1 era: the classic migration (contract 4), classic machines
// read-only until upgraded, and the typed plan refusals (contract 1.5) with "See plans".
import { describe, expect, test } from "bun:test";
import { canUpgradeClassic, migrationBanner } from "./account";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { canPause, canResume, changeable, defaultMemory, memoryChoices } from "./model";
import { ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const classic = () => sampleMachines().find((machine) => machine.classic)!;
const running = () => sampleMachines().find((machine) => machine.status === "running" && !machine.classic)!;

async function started(provider = new MockCloudProvider()) {
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}` });
  store.subscribe(() => undefined);
  await store.start();
  await settle();
  return { provider, store };
}

const runs = (provider: MockCloudProvider) =>
  provider.calls
    .filter((call) => call.op === ACTION_RUN)
    .map((call) => call.params as { action: string; args: Record<string, unknown> });

describe("classic migration", () => {
  test("the banner shows once when classic machines wait to move, and Later hides it", async () => {
    const { provider, store } = await started();
    expect(provider.calls.filter((call) => call.op === CloudOps.migrationStatus).length).toBe(1);
    expect(migrationBanner(store.getSnapshot())).toBe(1);
    store.account.dismissMigration();
    expect(migrationBanner(store.getSnapshot())).toBeUndefined();
    expect(runs(provider)).toEqual([]);
  });

  test("no banner without classic machines", async () => {
    const provider = new MockCloudProvider();
    provider.account.migration = { state: "none", classic_count: 0, imported: [] };
    const { store } = await started(provider);
    expect(migrationBanner(store.getSnapshot())).toBeUndefined();
  });

  test("Move them runs cloud.migration.start as a native action and the banner goes", async () => {
    const { provider, store } = await started();
    await store.account.startMigration();
    expect(provider.calls.some((call) => call.op === CloudOps.migrationStart)).toBe(false);
    expect(runs(provider)).toEqual([{ action: CloudOps.migrationStart, args: { idempotency_key: "k1" } }]);
    expect(store.getSnapshot().migration?.state).toBe("moving");
    expect(migrationBanner(store.getSnapshot())).toBeUndefined();
  });

  test("a declined move keeps the banner", async () => {
    const { store } = await started(new MockCloudProvider({ confirm: false }));
    await store.account.startMigration();
    expect(migrationBanner(store.getSnapshot())).toBe(1);
  });

  test("a classic machine is read-only: no pause, resume or changes", async () => {
    const { store } = await started();
    const row = store.getSnapshot().rows.find((r) => r.id === classic().id)!;
    expect(row.classic).toBe(true);
    expect(row.status).toBe("running");
    expect(changeable(row)).toBe(false);
    expect(canPause(row)).toBe(false);
    expect(canResume(row)).toBe(false);
    const other = store.getSnapshot().rows.find((r) => r.id === running().id)!;
    expect(canPause(other)).toBe(true);
  });

  test("upgrade runs as a native action after the move and the Classic badge goes on the echo", async () => {
    const provider = new MockCloudProvider();
    provider.account.migration = { state: "moved", classic_count: 1, imported: [classic().id] };
    const { store } = await started(provider);
    expect(canUpgradeClassic(store.getSnapshot().migration)).toBe(true);
    await store.upgrade(classic().id);
    expect(provider.calls.some((call) => call.op === CloudOps.machineUpgrade)).toBe(false);
    expect(runs(provider)).toEqual([
      { action: CloudOps.machineUpgrade, args: { machine: classic().id, idempotency_key: "k1" } },
    ]);
    expect(store.getSnapshot().pending).toEqual([]);
    expect(store.getSnapshot().rows.find((r) => r.id === classic().id)?.classic).toBeUndefined();
  });

  test("upgrade is not offered before the move", async () => {
    const { store } = await started();
    expect(canUpgradeClassic(store.getSnapshot().migration)).toBe(false);
  });
});

describe("plan limits and refusals", () => {
  test("the create sheet's sizes come from the plan; locked sizes are offered disabled", async () => {
    const { store } = await started();
    const plan = store.getSnapshot().plan!;
    expect(memoryChoices(plan)).toEqual([
      { mb: 4096, allowed: true },
      { mb: 8192, allowed: true },
      { mb: 16_384, allowed: false },
      { mb: 32_768, allowed: false },
    ]);
    expect(defaultMemory(plan)).toBe(4096);
    store.openCreate();
    expect(store.getSnapshot().create?.memoryMb).toBe(4096);
  });

  test("size_locked on create shows the refusal in the sheet, not the banner", async () => {
    const { store } = await started();
    store.openCreate();
    store.updateDraft({ memoryMb: 16_384 });
    await store.submitCreate();
    const draft = store.getSnapshot().create!;
    expect(draft.refusal).toEqual({ kind: "size_locked" });
    expect(draft.error).toBeUndefined();
    expect(draft.submitting).toBe(false);
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().pending).toEqual([]);
  });

  test("quota_exceeded carries the backend's limit and used", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_active = 3;
    const { store } = await started(provider);
    store.openCreate();
    await store.submitCreate();
    expect(store.getSnapshot().create?.refusal).toEqual({ kind: "quota_exceeded", limit: 3, used: 3 });
  });

  test("plan_required names the plan, and See plans runs the checkout natively with it", async () => {
    const provider = new MockCloudProvider();
    provider.planRequired = true;
    const { store } = await started(provider);
    store.openCreate();
    await store.submitCreate();
    const refusal = store.getSnapshot().create!.refusal!;
    expect(refusal).toEqual({ kind: "plan_required", plan: "pro" });
    await store.account.checkout(refusal.plan!);
    expect(provider.calls.some((call) => call.op === CloudOps.billingCheckout)).toBe(false);
    expect(runs(provider).at(-1)).toEqual({
      action: CloudOps.billingCheckout,
      args: { plan: "pro", idempotency_key: "k2" },
    });
  });

  test("a refusal outside the sheet (start over the limit) shows as the page notice", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_active = 3;
    const { store } = await started(provider);
    const paused = sampleMachines().find((machine) => machine.status === "paused")!;
    await store.resume(paused.id);
    expect(store.getSnapshot().refusal).toEqual({ kind: "quota_exceeded", limit: 3, used: 3 });
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().pending).toEqual([]);
    store.dismissError();
    expect(store.getSnapshot().refusal).toBeUndefined();
  });

  test("a snapshot over the saved limit shows the quota refusal", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_saved = 3;
    const { store } = await started(provider);
    await store.select(running().id);
    await settle();
    await store.detail.createSnapshot(running().id);
    expect(store.getSnapshot().refusal).toEqual({ kind: "quota_exceeded", limit: 3, used: 3 });
    expect(store.getSnapshot().error).toBeUndefined();
  });
});
