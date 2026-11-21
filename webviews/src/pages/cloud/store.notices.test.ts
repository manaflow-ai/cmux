// Cloud notices that went stale or came back: a plan refusal stayed after a plan read that no longer
// refuses (a raised or reset cap), and the classic migration banner's Later lasted only the page
// session, so the banner came back on every page open (error-states audit, 2026-11-12).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { keepMigrationLater, migrationBanner, migrationLater, planLifts } from "./account";
import { MockCloudProvider } from "./mockProvider";
import type { CloudPlan } from "./ops";
import { CloudStore } from "./store";

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

/** An in-memory `localStorage` for the page's kept Later. */
class MemoryStorage {
  private readonly items = new Map<string, string>();
  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.items.set(key, value);
  }
}
const scope = globalThis as Record<string, unknown>;
let savedStorage: unknown;
beforeEach(() => {
  savedStorage = scope.localStorage;
  scope.localStorage = new MemoryStorage();
});
afterEach(() => {
  if (savedStorage === undefined) delete scope.localStorage;
  else scope.localStorage = savedStorage;
});

const atCap = {
  state: "at_cap" as const,
  spent_usd: 503.1,
  cap_usd: 500,
  pause_at: null,
  paused_at: null,
  period_end: Date.UTC(2026, 11, 1),
  checked_at: Date.UTC(2026, 10, 18),
};

test("a spend refusal goes when the next plan read is under the cap; it stays while still at it", async () => {
  const provider = new MockCloudProvider();
  provider.spendCap = atCap;
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  await store.resume("vm_b2");
  await settle();
  expect(store.getSnapshot().refusal?.kind).toBe("spend_cap");
  // Still at the cap: the refusal is still true.
  await store.retryPlan();
  expect(store.getSnapshot().refusal?.kind).toBe("spend_cap");
  // An admin raised the cap: the next plan read lifts it.
  provider.spendCap = { ...atCap, state: "under", spent_usd: 10 };
  await store.retryPlan();
  expect(store.getSnapshot().refusal).toBeUndefined();
  unsubscribe();
});

test("a plan refusal is lifted by a new plan or by usage back under the machine limits", () => {
  const plan = new MockCloudProvider().plan;
  const full: CloudPlan = { ...plan, usage: { ...plan.usage, active: plan.limits.max_active } };
  expect(planLifts({ kind: "quota_exceeded" }, full, full)).toBe(false);
  expect(planLifts({ kind: "quota_exceeded" }, full, { ...full, usage: { ...full.usage, active: 0 } })).toBe(true);
  expect(planLifts({ kind: "plan_required" }, plan, plan)).toBe(false);
  expect(planLifts({ kind: "plan_required" }, plan, { ...plan, plan_id: "pro" })).toBe(true);
});

test("Later on the migration banner is kept for the account across page opens, not for another account", async () => {
  const provider = new MockCloudProvider();
  const first = new CloudStore(provider);
  const stop = first.subscribe(() => undefined);
  await settle();
  expect(migrationBanner(first.getSnapshot())).toBe(1);
  first.account.dismissMigration();
  expect(migrationBanner(first.getSnapshot())).toBeUndefined();
  stop();

  // The next page open, the same account: the banner stays hidden.
  const again = new CloudStore(provider);
  const stopAgain = again.subscribe(() => undefined);
  await settle();
  expect(migrationBanner(again.getSnapshot())).toBeUndefined();
  stopAgain();

  // Another account's Later is its own.
  keepMigrationLater("team_other");
  expect(migrationLater("team_other")).toBe(true);
  expect(migrationLater("team_third")).toBe(false);
});
