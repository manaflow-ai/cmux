import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { stripeCustomers } from "../db/schema";

// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const teamCustomer = {
  id: "team-signed-in",
  displayName: "Signed Team",
  listUsers: mock(async () => [{ id: "member-1" }, { id: "member-2" }]),
};
const signedInUser = {
  id: "user-signed-in",
  isAnonymous: false,
  primaryEmail: "signed@example.com",
  update: mock(async () => undefined),
  selectedTeam: null as null | typeof teamCustomer,
};
const anonymousUser = {
  id: "user-anonymous",
  isAnonymous: true,
  primaryEmail: null,
  update: mock(async () => undefined),
};

let userResponses: unknown[] = [];
const getUser = mock(async () => userResponses.shift() ?? null);
let stripeConfigured = false;
const createdStripeSessions: unknown[] = [];
const createdStripeCustomers: unknown[] = [];
const insertedStripeCustomers: Record<string, unknown>[] = [];
let stripeCustomerRows: { id: string }[] = [];
const createStripeSession = mock(async (params: unknown) => {
  createdStripeSessions.push(params);
  return { url: "https://checkout.stripe.com/c/session" };
});
const createStripeCustomer = mock(async (params: unknown) => {
  createdStripeCustomers.push(params);
  return { id: "cus_team" };
});
const resolveProPrice = mock(async (interval: unknown) =>
  interval === "month" ? "price_month" : "price_year",
);
const resolveTeamPrice = mock(async () => "price_team");
const stripeLimit = mock(async () => []);
let useStubDb = false;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

// Keep the real Pro resolver on the no-Stripe-subscription path regardless of
// process-global db mocks installed by other route suites.
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () =>
    useStubDb
      ? ({
          select: () => ({
            from: (table: unknown) => ({
              where: () => ({
                limit: table === stripeCustomers
                  ? mock(async () => stripeCustomerRows)
                  : stripeLimit,
              }),
            }),
          }),
          insert: () => ({
            values: (values: Record<string, unknown>) => {
              insertedStripeCustomers.push(values);
              return {
                then: (resolve: (value: unknown) => void) => resolve(undefined),
              };
            },
          }),
        } as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb(),
}));

mock.module("../services/billing/stripe", () => ({
  isStripeBillingConfigured: () => stripeConfigured,
  resolveProPrice,
  resolveTeamPrice,
  stripe: () => ({
    customers: {
      create: createStripeCustomer,
    },
    checkout: {
      sessions: {
        create: createStripeSession,
      },
    },
  }),
}));

const { GET } = await import("../app/api/billing/checkout/route");

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
});

describe("billing checkout route", () => {
  beforeEach(() => {
    getUser.mockClear();
    signedInUser.update.mockClear();
    teamCustomer.listUsers.mockClear();
    anonymousUser.update.mockClear();
    signedInUser.update.mockResolvedValue(undefined);
    teamCustomer.listUsers.mockResolvedValue([{ id: "member-1" }, { id: "member-2" }]);
    anonymousUser.update.mockResolvedValue(undefined);
    signedInUser.selectedTeam = null;
    userResponses = [];
    stripeConfigured = false;
    createdStripeSessions.length = 0;
    createdStripeCustomers.length = 0;
    insertedStripeCustomers.length = 0;
    stripeCustomerRows = [];
    createStripeSession.mockClear();
    createStripeCustomer.mockClear();
    resolveProPrice.mockClear();
    resolveTeamPrice.mockClear();
    stripeLimit.mockClear();
    stripeLimit.mockResolvedValue([]);
  });

  test("redirects to billing unavailable when Stripe is not configured", async () => {
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=unavailable",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("redirects team checkout to billing unavailable when Stripe is not configured", async () => {
    userResponses = [signedInUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=team"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=unavailable",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("blocks direct checkout requests from the iOS App Store distribution", async () => {
    stripeConfigured = true;
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/checkout?plan=pro&cmux_distribution=appstore&cmux_scheme=cmux",
      ),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/app-pricing?cmux_app=1&cmux_distribution=appstore&billing=unavailable",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("creates Stripe checkout for anonymous Pro visitors when configured", async () => {
    stripeConfigured = true;
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/session");
    expect(getUser).toHaveBeenNthCalledWith(1, { or: "return-null" });
    expect(getUser).toHaveBeenNthCalledWith(2, { or: "anonymous" });
    expect(resolveProPrice).toHaveBeenCalledWith("month");
    expect(createdStripeSessions).toHaveLength(1);
    expect(createdStripeSessions[0]).toMatchObject({
      mode: "subscription",
      line_items: [{ price: "price_month", quantity: 1 }],
      client_reference_id: "user-anonymous",
      metadata: { stackUserId: "user-anonymous", plan: "pro", app: "cmux" },
      subscription_data: {
        metadata: { stackUserId: "user-anonymous", plan: "pro", app: "cmux" },
      },
      allow_promotion_codes: true,
      customer_email: undefined,
      success_url:
        "https://cmux.test/api/billing/complete?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=cmux",
      cancel_url: "https://cmux.test/pricing?billing=cancelled",
    });
  });

  test("format=json returns the Stripe URL as JSON instead of a 302", async () => {
    stripeConfigured = true;
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?format=json"),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      url: "https://checkout.stripe.com/c/session",
    });
    expect(createdStripeSessions).toHaveLength(1);
  });

  test("format=json returns the redirect destination as JSON when Stripe is unconfigured", async () => {
    stripeConfigured = false;

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?format=json"),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      url: "https://cmux.test/pricing?billing=unavailable",
    });
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("uses yearly Stripe price when interval is year", async () => {
    stripeConfigured = true;
    userResponses = [signedInUser];

    await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?interval=year"),
    );

    expect(resolveProPrice).toHaveBeenCalledWith("year");
    expect(createdStripeSessions[0]).toMatchObject({
      customer_email: "signed@example.com",
      line_items: [{ price: "price_year", quantity: 1 }],
    });
  });

  test("rejects dev callback schemes on non-local Stripe checkout hosts", async () => {
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-test";
    stripeConfigured = true;
    userResponses = [null, anonymousUser];

    await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?cmux_scheme=cmux-dev-test"),
    );

    expect(createdStripeSessions[0]).toMatchObject({
      success_url:
        "https://cmux.test/api/billing/complete?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=cmux",
    });
  });

  test("creates Stripe checkout for Team subscriptions when configured", async () => {
    stripeConfigured = true;
    signedInUser.selectedTeam = teamCustomer;
    userResponses = [signedInUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=team"),
    );

    expect(response.headers.get("location")).toBe("https://checkout.stripe.com/c/session");
    expect(resolveTeamPrice).toHaveBeenCalled();
    expect(createStripeCustomer).toHaveBeenCalledWith({
      name: "Signed Team",
      metadata: { stackTeamId: "team-signed-in", app: "cmux" },
    });
    expect(insertedStripeCustomers).toContainEqual({
      id: "cus_team",
      stackUserId: "user-signed-in",
      stackTeamId: "team-signed-in",
      email: null,
    });
    expect(createdStripeSessions[0]).toMatchObject({
      mode: "subscription",
      line_items: [
        {
          price: "price_team",
          quantity: 2,
          adjustable_quantity: { enabled: true, minimum: 1 },
        },
      ],
      customer: "cus_team",
      client_reference_id: "team-signed-in",
      metadata: { stackTeamId: "team-signed-in", plan: "team", app: "cmux" },
      subscription_data: {
        metadata: { stackTeamId: "team-signed-in", plan: "team", app: "cmux" },
      },
      allow_promotion_codes: true,
      success_url:
        "https://cmux.test/api/billing/complete?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=cmux",
      cancel_url: "https://cmux.test/pricing?billing=cancelled",
    });
  });

  test("blocks Stripe Pro checkout while account deletion is in progress", async () => {
    stripeConfigured = true;
    userResponses = [{
      ...signedInUser,
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=account_deletion_in_progress",
    );
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("blocks Stripe team checkout while account deletion is in progress", async () => {
    stripeConfigured = true;
    userResponses = [{
      ...signedInUser,
      selectedTeam: teamCustomer,
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=team"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=account_deletion_in_progress",
    );
    expect(createStripeCustomer).not.toHaveBeenCalled();
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("rejects unknown checkout plans", async () => {
    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=enterprise"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=invalid_plan",
    );
    expect(getUser).not.toHaveBeenCalled();
  });
});
