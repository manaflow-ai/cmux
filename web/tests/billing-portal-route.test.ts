import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { stripeCustomers, stripeSubscriptions } from "../db/schema";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const stripeModule = await import("../services/billing/stripe");

const signedInUser = {
  id: "user-pro",
  isAnonymous: false,
  clientReadOnlyMetadata: {},
  listProducts: mock(async () =>
    Object.assign(
      stackProductsActive
        ? [
            {
              id: "pro",
              quantity: 1,
              subscription: {
                cancelAtPeriodEnd: false,
                currentPeriodEnd: null,
              },
            },
          ]
        : [],
      { nextCursor: null },
    ),
  ),
  update: mock(async () => undefined),
};
const anonymousUser = {
  id: "anonymous-pro",
  isAnonymous: true,
  clientReadOnlyMetadata: {},
  listProducts: mock(async () => Object.assign([], { nextCursor: null })),
  update: mock(async () => undefined),
};

let stackConfigured = true;
let stripeConfigured = true;
let returnNullUser: unknown = signedInUser;
let anonymousIfExistsUser: unknown = null;
let customerRows: { id: string }[] = [{ id: "cus_123" }];
let stripeSubscriptionRows: { id: string }[] = [];
let stackProductsActive = false;

const getUser = mock(async (options?: unknown) => {
  const or =
    options && typeof options === "object" && "or" in options
      ? (options.or as unknown)
      : undefined;
  if (or === "anonymous-if-exists[deprecated]") {
    return anonymousIfExistsUser;
  }
  return returnNullUser;
});
const createPortalSession = mock(async (params: unknown) => ({
  url: "https://billing.stripe.com/session/test",
  params,
}));
const captureBillingError = mock(() => undefined);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => ({
    select: () => ({
      from: (table: unknown) => ({
        where: () => ({
          limit: mock(async () => {
            if (table === stripeCustomers) return customerRows;
            if (table === stripeSubscriptions) return stripeSubscriptionRows;
            return [];
          }),
        }),
      }),
    }),
  }),
}));

mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => stripeConfigured,
  stripe: () => ({
    billingPortal: {
      sessions: {
        create: createPortalSession,
      },
    },
  }),
}));

mock.module("../services/errors", () => ({
  captureBillingError,
}));

const { GET } = await import("../app/api/billing/portal/route");

describe("billing portal route", () => {
  beforeEach(() => {
    stackConfigured = true;
    stripeConfigured = true;
    returnNullUser = signedInUser;
    anonymousIfExistsUser = null;
    customerRows = [{ id: "cus_123" }];
    stripeSubscriptionRows = [];
    stackProductsActive = false;
    getUser.mockClear();
    signedInUser.listProducts.mockClear();
    signedInUser.update.mockClear();
    anonymousUser.listProducts.mockClear();
    anonymousUser.update.mockClear();
    createPortalSession.mockClear();
    createPortalSession.mockResolvedValue({
      url: "https://billing.stripe.com/session/test",
    });
    captureBillingError.mockClear();
  });

  test("redirects signed-in users with a Stripe customer row to the portal session", async () => {
    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://billing.stripe.com/session/test",
    );
    expect(createPortalSession).toHaveBeenCalledWith({
      customer: "cus_123",
      return_url: "https://cmux.test/pricing",
    });
    expect(getUser).toHaveBeenCalledWith({ or: "return-null" });
  });

  test("falls back to an existing anonymous purchaser and opens that portal", async () => {
    returnNullUser = null;
    anonymousIfExistsUser = anonymousUser;
    customerRows = [{ id: "cus_anonymous" }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://billing.stripe.com/session/test",
    );
    expect(getUser).toHaveBeenCalledTimes(2);
    expect(getUser).toHaveBeenCalledWith({ or: "return-null" });
    expect(getUser).toHaveBeenCalledWith({ or: "anonymous-if-exists[deprecated]" });
    expect(createPortalSession).toHaveBeenCalledWith({
      customer: "cus_anonymous",
      return_url: "https://cmux.test/pricing",
    });
  });

  test("redirects to pricing when no user is resolved", async () => {
    returnNullUser = null;
    anonymousIfExistsUser = null;

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing",
    );
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("redirects to billing unavailable when Stripe is not configured", async () => {
    stripeConfigured = false;

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=unavailable",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("redirects legacy Pro users without a Stripe customer row to external billing", async () => {
    customerRows = [];
    stackProductsActive = true;

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=external",
    );
    expect(captureBillingError).not.toHaveBeenCalled();
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("captures missing customer rows for Stripe-managed users and redirects external", async () => {
    customerRows = [];
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=external",
    );
    expect(captureBillingError).toHaveBeenCalledWith(
      expect.objectContaining({
        message: "Stripe-managed billing user is missing a Stripe customer row",
      }),
      expect.objectContaining({
        route: "/api/billing/portal",
        stackUserId: "user-pro",
        billingManagement: "stripe",
      }),
    );
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("redirects to billing error when Stripe portal session creation fails", async () => {
    mockImplementation(createPortalSession, async () => {
      throw new Error("stripe down");
    });

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=error",
    );
    expect(captureBillingError).toHaveBeenCalled();
  });

  test("captures missing portal configuration context from Stripe errors", async () => {
    mockImplementation(createPortalSession, async () => {
      throw new Error("Billing Portal is not configured for this account");
    });

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=error",
    );
    expect(captureBillingError).toHaveBeenCalledWith(
      expect.objectContaining({
        message: "Billing Portal is not configured for this account",
      }),
      expect.objectContaining({
        route: "/api/billing/portal",
        stackUserId: "user-pro",
        stripePortalConfigurationMissing: true,
      }),
    );
  });
});

function mockImplementation(
  fn: unknown,
  implementation: (...args: never[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}
