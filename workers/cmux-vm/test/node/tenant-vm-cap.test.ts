import { expect, it } from "vitest";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";
import { TenantId } from "../../src/lib/ids.ts";
import { DEFAULT_DEV_TEST_MAX_VMS, makeTenantPolicy, NO_VM_COUNT_CAP } from "../../src/policy.ts";

const tenant = (id: string) => TenantId.make(id);

it("gives a production product tenant no machine-count cap, and keeps dev/test tenants and listed quotas capped", () => {
  const policy = makeTenantPolicy({
    environment: "production",
    devTestTenantIds: ["team_smoke"],
    vmQuotas: { team_capped: 3 },
  });
  expect(policy.maxVms(tenant("team_paying"))).toBe(NO_VM_COUNT_CAP);
  expect(policy.maxVms(tenant("team_smoke"))).toBe(DEFAULT_DEV_TEST_MAX_VMS);
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
