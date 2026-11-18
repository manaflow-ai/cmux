import { expect, it } from "vitest";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";
import { TenantId } from "../../src/lib/ids.ts";
import { DEFAULT_DEV_TEST_MAX_VMS, makeTenantPolicy, NO_VM_COUNT_CAP, PRODUCTION_DEV_TEST_MAX_VMS } from "../../src/policy.ts";

const tenant = (id: string) => TenantId.make(id);

it("gives a production product tenant no machine-count cap, and keeps dev/test tenants and listed quotas capped", () => {
  const policy = makeTenantPolicy({
    environment: "production",
    devTestTenantIds: ["team_smoke"],
    vmQuotas: { team_capped: 3 },
  });
  expect(policy.maxVms(tenant("team_paying"))).toBe(NO_VM_COUNT_CAP);
  // The production smoke tenant stays at 20: a leaked smoke loop there runs on the real account.
  expect(policy.maxVms(tenant("team_smoke"))).toBe(PRODUCTION_DEV_TEST_MAX_VMS);
  expect(PRODUCTION_DEV_TEST_MAX_VMS).toBe(20);
  expect(policy.maxVms(tenant("team_capped"))).toBe(3);
  // Off production every tenant is dev/test.
  expect(makeTenantPolicy({ environment: "staging" }).maxVms(tenant("team_paying"))).toBe(DEFAULT_DEV_TEST_MAX_VMS);
});

it("admits a product tenant's create past the old 20-machine cap", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  const limit = makeTenantPolicy({ environment: "production" }).maxVms(tenant("team_paying"));
  expect(await ledger.reserve("vm", limit, 500, 0, "past-twenty")).toEqual({ ok: true, reservationId: "past-twenty" });
  expect(await ledger.reserve("vm", 20, 20, 0, "at-twenty")).toEqual({ ok: false });
});

it("admits an off-production team holding 20 machines, paused ones too, as a plan above 20 allows (#45885)", async () => {
  // Development teams hold machines under cmux-platform plans of 50 (NEXT Pro), 100 (company) and 300 (NEXT Max)
  // machines kept; the provider's own cap must not stop them first at 20.
  const ledger = new TenantLedger(memoryLedgerStorage());
  const limit = makeTenantPolicy({ environment: "staging" }).maxVms(tenant("team_next_max"));
  expect(limit).toBeGreaterThanOrEqual(300);
  expect(await ledger.reserve("vm", limit, 20, 0, "twenty-first")).toEqual({ ok: true, reservationId: "twenty-first" });
  // Still a cap: a leaked test loop stops at it.
  expect(await ledger.reserve("vm", limit, limit, 0, "past-cap")).toEqual({ ok: false });
});
