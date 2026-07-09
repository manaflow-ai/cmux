import { describe, expect, test } from "bun:test";
import { call } from "@orpc/server";

import { accountMeProcedure } from "../orpc/server/account/me";
import { generateOpenAPIDocument } from "../orpc/server/openapi";
import { PRO_PRODUCT_ID } from "../services/billing/pro";

// Drives the real resolveProPlanStatus (no module mocks, so it can't leak into
// other test files). The fake user carries no `id`, so the Stripe-subscription
// lookup short-circuits to false and no database is touched; the Stack product
// list alone decides Pro vs Free.
type FakeProduct = {
  id: string;
  subscription: { currentPeriodEnd: Date | null } | null;
  quantity: number;
};

function productsPage(items: FakeProduct[]) {
  const page = [...items] as FakeProduct[] & { nextCursor: string | null };
  page.nextCursor = null;
  return page;
}

function fakeUser(opts: { email: string | null; pro: boolean }) {
  return {
    primaryEmail: opts.email,
    clientReadOnlyMetadata: {},
    listProducts: async () =>
      productsPage(
        opts.pro ? [{ id: PRO_PRODUCT_ID, subscription: null, quantity: 1 }] : [],
      ),
    update: async () => undefined,
  };
}

function context(user: unknown) {
  return { request: new Request("http://localhost/api/rpc"), user } as never;
}

describe("account.me", () => {
  test("returns the Pro plan (external billing) for a Stack-Pro user", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser({ email: "a@example.com", pro: true })),
    });
    expect(result).toEqual({
      userId: "",
      email: "a@example.com",
      planId: "pro",
      isPro: true,
      billingManagement: "external",
    });
  });

  test("returns the Free plan and an empty email for an email-less non-subscriber", async () => {
    const result = await call(accountMeProcedure, undefined, {
      context: context(fakeUser({ email: null, pro: false })),
    });
    expect(result.planId).toBe("free");
    expect(result.isPro).toBe(false);
    expect(result.email).toBe("");
    expect(result.billingManagement).toBe("none");
  });

  test("rejects unauthenticated callers before resolving a plan", async () => {
    await expect(
      call(accountMeProcedure, undefined, { context: context(null) }),
    ).rejects.toThrow();
  });

  test("OpenAPI document advertises account.me at GET /account/me on /api/v1", async () => {
    const doc = await generateOpenAPIDocument();
    const operation = (doc.paths?.["/account/me"] as { get?: { operationId?: string } } | undefined)
      ?.get;
    expect(operation?.operationId).toBe("account.me");
    expect(doc.servers?.[0]?.url).toBe("/api/v1");
  });
});
