import { expect, it } from "vitest";
import { memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";
import type { TenantId } from "../../src/lib/ids.ts";
import { DEFAULT_DEV_TEST_MAX_VMS, makeTenantPolicy, NO_VM_COUNT_CAP } from "../../src/policy.ts";

const tenant = (id: string) => id as TenantId;

it("gives a production product tenant no machine-count cap, and keeps dev/test tenants and listed quotas capped", () => {
  const policy = makeTenantPolicy({
    environment: "production",
    devTestTenantIds: ["smoke"],
    vmQuotas: { "capped-team": 3 },
  });
  expect(policy.maxVms(tenant("paying-team"))).toBe(NO_VM_COUNT_CAP);
  expect(policy.maxVms(tenant("smoke"))).toBe(DEFAULT_DEV_TEST_MAX_VMS);
  expect(policy.maxVms(tenant("capped-team"))).toBe(3);
  // Off production every tenant is dev/test.
  expect(makeTenantPolicy({ environment: "staging" }).maxVms(tenant("paying-team"))).toBe(DEFAULT_DEV_TEST_MAX_VMS);
});

it("admits a product tenant's create past the old 20-machine cap", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  const limit = makeTenantPolicy({ environment: "production" }).maxVms(tenant("paying-team"));
  expect(await ledger.reserve("vm", limit, 500, 0, "past-twenty")).toEqual({ ok: true, reservationId: "past-twenty" });
  expect(await ledger.reserve("vm", 20, 20, 0, "at-twenty")).toEqual({ ok: false });
});
