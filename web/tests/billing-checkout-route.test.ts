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
  createCheckoutUrl: mock(async () => "https://checkout.test/team"),
};
const signedInUser = {
  id: "user-signed-in",
  isAnonymous: false,
  primaryEmail: "signed@example.com",
  createCheckoutUrl: mock(async () => "https://checkout.test/signed-in"),
  listProducts: mock(async () => emptyProductsPage()),
  update: mock(async () => undefined),
  selectedTeam: null as null | typeof teamCustomer,
};
const anonymousUser = {
  id: "user-anonymous",
  isAnonymous: true,
  primaryEmail: null,
  createCheckoutUrl: mock(async () => "https://checkout.test/anonymous"),
  listProducts: mock(async () => emptyProductsPage()),
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
  stackHandlerApp: null,
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
    signedInUser.createCheckoutUrl.mockClear();
    signedInUser.listProducts.mockClear();
    signedInUser.update.mockClear();
    teamCustomer.createCheckoutUrl.mockClear();
    teamCustomer.listUsers.mockClear();
    anonymousUser.createCheckoutUrl.mockClear();
    anonymousUser.listProducts.mockClear();
    anonymousUser.update.mockClear();
    signedInUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/signed-in");
    signedInUser.listProducts.mockResolvedValue(emptyProductsPage());
    signedInUser.update.mockResolvedValue(undefined);
    teamCustomer.createCheckoutUrl.mockResolvedValue("https://checkout.test/team");
    teamCustomer.listUsers.mockResolvedValue([{ id: "member-1" }, { id: "member-2" }]);
    anonymousUser.createCheckoutUrl.mockResolvedValue("https://checkout.test/anonymous");
    anonymousUser.listProducts.mockResolvedValue(emptyProductsPage());
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

  test("sends signed-out visitors straight to anonymous Stack checkout", async () => {
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.test/anonymous");
    expect(getUser).toHaveBeenNthCalledWith(1, { or: "return-null" });
    expect(getUser).toHaveBeenNthCalledWith(2, { or: "anonymous" });
    expect(anonymousUser.createCheckoutUrl).toHaveBeenCalledWith({
      productId: "pro",
      returnUrl: "https://cmux.test/api/billing/confirm",
    });
  });

  test("keeps signed-in checkout on the existing Stack user", async () => {
    userResponses = [signedInUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.test/signed-in");
    expect(getUser).toHaveBeenCalledTimes(1);
    expect(signedInUser.createCheckoutUrl).toHaveBeenCalledWith({
      productId: "pro",
      returnUrl: "https://cmux.test/api/billing/confirm",
    });
  });

  test("syncs metadata when Stack says Pro checkout is already granted and products confirm it", async () => {
    userResponses = [signedInUser];
    mockImplementation(signedInUser.createCheckoutUrl, async () => {
      throw new Error("Product already granted to customer");
    });
    // First read (the route's top pre-check) sees no Pro so the route reaches
    // createCheckoutUrl; the catch-path re-verify then sees an active Pro.
    let listProductsCalls = 0;
    mockImplementation(signedInUser.listProducts, async () =>
      listProductsCalls++ === 0 ? emptyProductsPage() : activeProProductsPage(),
    );

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?welcome=active",
    );
    expect(signedInUser.createCheckoutUrl).toHaveBeenCalledTimes(1);
    expect(signedInUser.listProducts).toHaveBeenCalled();
    expect(signedInUser.update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("does not mint Pro metadata when Stack says already granted but products do not confirm it", async () => {
    userResponses = [signedInUser];
    mockImplementation(signedInUser.createCheckoutUrl, async () => {
      throw new Error("Product already granted to customer");
    });
    signedInUser.listProducts.mockResolvedValue(emptyProductsPage());

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/api/billing/confirm",
    );
    expect(signedInUser.listProducts).toHaveBeenCalled();
    expect(signedInUser.update).not.toHaveBeenCalled();
  });

  test("routes team checkout through the team Stack product", async () => {
    signedInUser.selectedTeam = teamCustomer;
    userResponses = [signedInUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout?plan=team"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://checkout.test/team");
    expect(signedInUser.listProducts).not.toHaveBeenCalled();
    expect(signedInUser.createCheckoutUrl).not.toHaveBeenCalled();
    expect(teamCustomer.createCheckoutUrl).toHaveBeenCalledWith({
      productId: "team",
      returnUrl: "https://cmux.test/pricing?welcome=team",
    });
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
    expect(teamCustomer.createCheckoutUrl).not.toHaveBeenCalled();
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

function emptyProductsPage() {
  return Object.assign([], { nextCursor: null });
}

function activeProProductsPage() {
  return Object.assign(
    [
      {
        id: "pro",
        quantity: 1,
        subscription: {
          cancelAtPeriodEnd: false,
          currentPeriodEnd: null,
        },
      },
    ],
    { nextCursor: null },
  );
}

function mockImplementation(
  fn: unknown,
  implementation: (...args: never[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}
