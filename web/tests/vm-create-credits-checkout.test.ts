import { describe, expect, test } from "bun:test";

import { VmCreateCreditsInsufficientError } from "../services/vms/errors";
import { VM_CREATE_CREDITS_CHECKOUT_URL, vmCreateLikeErrorResponse } from "../services/vms/routeHelpers";

// A tenant with no Cloud VM create credits must get a checkout link it can open,
// not a dead "ask an admin" error (plans/freestyle-tenant-DESIGN.md in cmuxterm-hq).
describe("Cloud VM create credits exhausted", () => {
  test("the checkout link is a cmux checkout page", () => {
    const url = new URL(VM_CREATE_CREDITS_CHECKOUT_URL);
    expect(url.origin).toBe("https://cmux.com");
    expect(url.pathname).toBe("/api/billing/checkout");
    expect(url.searchParams.get("plan")).toBe("pro");
    expect(url.searchParams.get("cmux_source")).toBe("vm_create_credits");
  });

  for (const operation of ["fork", "restore"] as const) {
    test(`${operation} refusal carries the checkout link`, async () => {
      const response = await vmCreateLikeErrorResponse(
        new VmCreateCreditsInsufficientError({ itemId: "cmux-vm-create-credit", billingCustomerId: "team-1", amount: 1 }),
        { operation, planId: "free", retryAction: "retry" },
      );
      expect(response?.status).toBe(402);
      const payload = await response!.json();
      expect(payload).toMatchObject({
        error: "vm_create_credits_insufficient",
        amount: 1,
        upgradeRequired: true,
        upgradePlanId: "pro",
        upgradeUrl: VM_CREATE_CREDITS_CHECKOUT_URL,
      });
      expect(payload.action).toContain(VM_CREATE_CREDITS_CHECKOUT_URL);
    });
  }
});
