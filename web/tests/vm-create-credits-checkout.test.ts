import { describe, expect, test } from "bun:test";

import { VmCreateCreditsInsufficientError } from "../services/vms/errors";
import {
  VM_CREATE_CREDITS_CHECKOUT_URL,
  vmCreateCreditsCheckoutExtra,
  vmCreateLikeErrorResponse,
} from "../services/vms/routeHelpers";

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

  test("a paid tenant is sent to the next plan up, never to the plan it has", () => {
    for (const planId of ["pro", "team", "founders"]) {
      const extra = vmCreateCreditsCheckoutExtra(1, planId);
      expect(extra.upgradePlanId).toBe("max");
      expect(new URL(extra.upgradeUrl).searchParams.get("plan")).toBe("max");
      expect(new URL(extra.upgradeUrl).searchParams.get("cmux_source")).toBe("vm_create_credits");
    }
  });

  test("a Max tenant has no plan to buy, so it gets the pricing page", () => {
    const extra = vmCreateCreditsCheckoutExtra(1, "max");
    expect(extra.upgradeRequired).toBe(true);
    expect(extra.upgradePlanId).toBeNull();
    expect(extra.upgradeUrl).toBe("https://cmux.com/pricing");
  });

  test("an unpaid tenant goes to the Pro checkout", () => {
    for (const planId of ["free", "go", ""]) {
      expect(vmCreateCreditsCheckoutExtra(1, planId).upgradeUrl).toBe(VM_CREATE_CREDITS_CHECKOUT_URL);
    }
  });
});
