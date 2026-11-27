import { expect, it } from "vitest";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";
import { TenantId } from "../../src/lib/ids.ts";
import { DEFAULT_DEV_TEST_MAX_VMS, makeTenantPolicy, NO_VM_COUNT_CAP, PRODUCTION_DEV_TEST_MAX_VMS } from "../../src/policy.ts";

const tenant = (id: string) => TenantId.make(id);

it("gives product and off-production tenants no machine-count cap, and keeps the production smoke tenant and listed quotas capped", () => {
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
  // Off production every tenant is dev/test, and none has a count cap: reapers and idle pause reclaim leaks.
  expect(DEFAULT_DEV_TEST_MAX_VMS).toBe(NO_VM_COUNT_CAP);
  expect(makeTenantPolicy({ environment: "staging" }).maxVms(tenant("team_paying"))).toBe(NO_VM_COUNT_CAP);
  expect(makeTenantPolicy({ environment: "staging", vmQuotas: { team_capped: 3 } }).maxVms(tenant("team_capped"))).toBe(3);
});

it("admits a product tenant's create past the old 20-machine cap", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  const limit = makeTenantPolicy({ environment: "production" }).maxVms(tenant("team_paying"));
  expect(await ledger.reserve("vm", limit, 500, 0, "past-twenty")).toEqual({ ok: true, reservationId: "past-twenty" });
  expect(await ledger.reserve("vm", 20, 20, 0, "at-twenty")).toEqual({ ok: false });
});

it("admits an off-production team's create past the old 300-machine cap (staging drills hit 300 of 300)", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  const limit = makeTenantPolicy({ environment: "staging" }).maxVms(tenant("team_staging_tests"));
  expect(await ledger.reserve("vm", limit, 20, 0, "twenty-first")).toEqual({ ok: true, reservationId: "twenty-first" });
  expect(await ledger.reserve("vm", limit, 300, 0, "three-hundred-first")).toEqual({
    ok: true,
    reservationId: "three-hundred-first",
  });
  expect(await ledger.reserve("vm", limit, 5000, 0, "far-past")).toEqual({ ok: true, reservationId: "far-past" });
});
