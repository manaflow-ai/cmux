import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { stripeCustomers, stripeSubscriptions } from "../db/schema";

// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const SIGNED_IN_USER_ID = "7f5e4e80-3d96-4f6a-8f2e-3c1e4a4d0d01";
const ANONYMOUS_USER_ID = "5a0f6f7a-7d9f-4bc5-a3be-2d11f7a6c902";
const TEAM_ID = "9b6e2d4c-1a73-4f05-b8d9-6c0e2a5f3b14";
const CHECKOUT_SESSION_ID = "cs_test_checkout";

const teamCustomer = {
  id: TEAM_ID,
  displayName: "Signed Team",
  listUsers: mock(async () => [{ id: "member-1" }, { id: "member-2" }]),
};
const signedInUser = {
  id: SIGNED_IN_USER_ID,
  isAnonymous: false,
  primaryEmail: "signed@example.com",
  update: mock(async () => undefined),
  selectedTeam: null as null | typeof teamCustomer,
};
const anonymousUser = {
  id: ANONYMOUS_USER_ID,
  isAnonymous: true,
  primaryEmail: null,
  update: mock(async () => undefined),
};

let userResponses: unknown[] = [];
let stackAuthUnavailable = false;
const getUser = mock(async () => {
  if (stackAuthUnavailable) throw new Error("Stack Auth unavailable");
  return userResponses.shift() ?? null;
});
let stripeConfigured = false;
const createdStripeSessions: unknown[] = [];
const createdStripeCustomers: unknown[] = [];
const insertedStripeCustomers: Record<string, unknown>[] = [];
let stripeCustomerRows: { id: string }[] = [];
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];
let stripeActiveSubscriptionRows: Array<Record<string, unknown>> = [];
let stripeSessionResponse: { readonly id?: string; readonly url?: string } = {
  id: CHECKOUT_SESSION_ID,
  url: "https://checkout.stripe.com/c/session",
};
const createStripeSession = mock(async (params: unknown) => {
  createdStripeSessions.push(params);
  return stripeSessionResponse;
});
const createStripeCustomer = mock(async (params: unknown) => {
  createdStripeCustomers.push(params);
  return { id: "cus_team" };
});
const resolveProPrice = mock(async (interval: unknown) =>
  interval === "month" ? "price_month" : "price_year",
);
const resolveTeamPrice = mock(async (interval: unknown) =>
  interval === "month" ? "price_team_month" : "price_team_year",
);
const stripeLimit = mock(async () => []);
let useStubDb = false;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  promoteStackUserFromAnonymousViaApi: mock(async () => undefined),
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
                  : table === stripeSubscriptions
                    ? mock(async () => stripeActiveSubscriptionRows)
                    : stripeLimit,
                orderBy: () => ({
                  limit: table === stripeSubscriptions
                    ? mock(async () => stripeSubscriptionRows)
                    : table === stripeCustomers
                      ? mock(async () => stripeCustomerRows)
                      : stripeLimit,
                }),
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

// Checkout tests must never exercise the real PostHog transport. The analytics
// module has its own test-mode guard, but this route seam also lets these tests
// assert the exact event contract without starting a background request.
const actualStripeBillingModule = await import("../services/analytics/stripeBilling");
const realCaptureBillingCheckoutStarted =
  actualStripeBillingModule.captureBillingCheckoutStarted;
type CaptureBillingCheckoutStartedMock =
  typeof actualStripeBillingModule.captureBillingCheckoutStarted & {
    mockClear: () => void;
    mockResolvedValue: (value: unknown) => void;
  };
const captureBillingCheckoutStarted: CaptureBillingCheckoutStartedMock = mock(
  async (...args: unknown[]): Promise<void> => {
    await Reflect.apply(realCaptureBillingCheckoutStarted, undefined, args);
  },
);
mock.module("../services/analytics/stripeBilling", () => ({
  ...actualStripeBillingModule,
  captureBillingCheckoutStarted,
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
    stackAuthUnavailable = false;
    stripeConfigured = false;
    createdStripeSessions.length = 0;
    createdStripeCustomers.length = 0;
    insertedStripeCustomers.length = 0;
    stripeCustomerRows = [];
    stripeSubscriptionRows = [];
    stripeActiveSubscriptionRows = [];
    stripeSessionResponse = {
      id: CHECKOUT_SESSION_ID,
      url: "https://checkout.stripe.com/c/session",
    };
    createStripeSession.mockClear();
    createStripeCustomer.mockClear();
    resolveProPrice.mockClear();
    resolveTeamPrice.mockClear();
    captureBillingCheckoutStarted.mockClear();
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
        "https://cmux.test/api/billing/checkout?plan=pro&interval=year&cmux_distribution=appstore&cmux_scheme=cmux",
      ),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/app-pricing?cmux_app=1&cmux_distribution=appstore&billing=unavailable&interval=year",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("relays an app-pricing checkout through the server-configured destination", async () => {
    const previous = process.env.CMUX_APP_PRICING_CHECKOUT_URL;
    process.env.CMUX_APP_PRICING_CHECKOUT_URL =
      "https://billing.example/checkout?campaign=annual";
    try {
      const response = await GET(
        new NextRequest(
          "https://cmux.test/api/billing/checkout?plan=team&interval=year&cmux_scheme=cmux-dev-test&cmux_app_checkout=1",
        ),
      );

      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe(
        "https://billing.example/checkout?campaign=annual&plan=team&interval=year&cmux_scheme=cmux",
      );
      expect(getUser).not.toHaveBeenCalled();
      expect(createStripeSession).not.toHaveBeenCalled();
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_APP_PRICING_CHECKOUT_URL;
      } else {
        process.env.CMUX_APP_PRICING_CHECKOUT_URL = previous;
      }
    }
  });

  test("preserves a validated tagged callback through the configured relay", async () => {
    const previousURL = process.env.CMUX_APP_PRICING_CHECKOUT_URL;
    const previousSecret = process.env.CMUX_APP_PRICING_RELAY_SECRET;
    const previousSchemes = process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES;
    process.env.CMUX_APP_PRICING_CHECKOUT_URL =
      "https://billing.example/api/billing/checkout";
    process.env.CMUX_APP_PRICING_RELAY_SECRET =
      "pricing-relay-test-secret-with-at-least-32-bytes";
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-test";
    try {
      const relayResponse = await GET(
        new NextRequest(
          "http://localhost:4100/api/billing/checkout?plan=pro&interval=year&cmux_scheme=cmux-dev-test&cmux_app_checkout=1",
        ),
      );
      const relayLocation = relayResponse.headers.get("location");
      expect(relayLocation).toBeString();
      const relayURL = new URL(relayLocation!);
      expect(relayURL.origin).toBe("https://billing.example");
      expect(relayURL.searchParams.get("cmux_scheme")).toBe("cmux-dev-test");
      expect(relayURL.searchParams.get("cmux_relay_expires")).toMatch(/^\d+$/);
      expect(relayURL.searchParams.get("cmux_relay_signature")).toMatch(
        /^[a-f0-9]{64}$/,
      );

      delete process.env.CMUX_APP_PRICING_CHECKOUT_URL;
      stripeConfigured = true;
      userResponses = [null, anonymousUser];
      const originalNow = Date.now;
      let checkoutResponse: Awaited<ReturnType<typeof GET>>;
      try {
        const verifierNow = originalNow() - 1_000;
        Date.now = () => verifierNow;
        checkoutResponse = await GET(new NextRequest(relayURL));
      } finally {
        Date.now = originalNow;
      }

      expect(checkoutResponse.headers.get("location")).toBe(
        "https://checkout.stripe.com/c/session",
      );
      expect(createdStripeSessions).toHaveLength(1);
      expect(createdStripeSessions[0]).toMatchObject({
        metadata: { nativeCallbackScheme: "cmux-dev-test" },
        subscription_data: {
          metadata: { nativeCallbackScheme: "cmux-dev-test" },
        },
        success_url:
          "https://billing.example/api/billing/complete?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=cmux-dev-test",
      });

      createdStripeSessions.length = 0;
      userResponses = [null, anonymousUser];
      const signature = relayURL.searchParams.get("cmux_relay_signature")!;
      relayURL.searchParams.set(
        "cmux_relay_signature",
        `${signature[0] === "0" ? "1" : "0"}${signature.slice(1)}`,
      );
      const invalidRelayResponse = await GET(new NextRequest(relayURL));
      expect(invalidRelayResponse.headers.get("location")).toBe(
        "https://billing.example/pricing?billing=invalid_relay",
      );
      expect(createdStripeSessions).toHaveLength(0);
    } finally {
      if (previousURL === undefined) {
        delete process.env.CMUX_APP_PRICING_CHECKOUT_URL;
      } else {
        process.env.CMUX_APP_PRICING_CHECKOUT_URL = previousURL;
      }
      if (previousSecret === undefined) {
        delete process.env.CMUX_APP_PRICING_RELAY_SECRET;
      } else {
        process.env.CMUX_APP_PRICING_RELAY_SECRET = previousSecret;
      }
      if (previousSchemes === undefined) {
        delete process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES;
      } else {
        process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = previousSchemes;
      }
    }
  });

  test("does not sign tagged callback relays from a public request origin", async () => {
    const previousURL = process.env.CMUX_APP_PRICING_CHECKOUT_URL;
    const previousSecret = process.env.CMUX_APP_PRICING_RELAY_SECRET;
    const previousSchemes = process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES;
    process.env.CMUX_APP_PRICING_CHECKOUT_URL =
      "https://billing.example/api/billing/checkout";
    process.env.CMUX_APP_PRICING_RELAY_SECRET =
      "pricing-relay-test-secret-with-at-least-32-bytes";
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-test";
    try {
      const response = await GET(
        new NextRequest(
          "https://cmux.test/api/billing/checkout?plan=pro&interval=year&cmux_scheme=cmux-dev-test&cmux_app_checkout=1",
        ),
      );
      const location = response.headers.get("location");
      expect(location).toBeString();
      const relayURL = new URL(location!);

      expect(relayURL.searchParams.get("cmux_scheme")).toBe("cmux");
      expect(relayURL.searchParams.has("cmux_relay_expires")).toBe(false);
      expect(relayURL.searchParams.has("cmux_relay_signature")).toBe(false);
    } finally {
      if (previousURL === undefined) {
        delete process.env.CMUX_APP_PRICING_CHECKOUT_URL;
      } else {
        process.env.CMUX_APP_PRICING_CHECKOUT_URL = previousURL;
      }
      if (previousSecret === undefined) {
        delete process.env.CMUX_APP_PRICING_RELAY_SECRET;
      } else {
        process.env.CMUX_APP_PRICING_RELAY_SECRET = previousSecret;
      }
      if (previousSchemes === undefined) {
        delete process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES;
      } else {
        process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = previousSchemes;
      }
    }
  });

  test("rejects invalid app-pricing relay parameters before forwarding", async () => {
    const previous = process.env.CMUX_APP_PRICING_CHECKOUT_URL;
    process.env.CMUX_APP_PRICING_CHECKOUT_URL =
      "https://billing.example/checkout";
    try {
      const response = await GET(
        new NextRequest(
          "https://cmux.test/api/billing/checkout?plan=enterprise&interval=forever&cmux_scheme=https&cmux_app_checkout=1",
        ),
      );

      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe(
        "https://cmux.test/pricing?billing=invalid_plan",
      );
      expect(getUser).not.toHaveBeenCalled();
      expect(createStripeSession).not.toHaveBeenCalled();
    } finally {
      if (previous === undefined) {
        delete process.env.CMUX_APP_PRICING_CHECKOUT_URL;
      } else {
        process.env.CMUX_APP_PRICING_CHECKOUT_URL = previous;
      }
    }
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
      client_reference_id: ANONYMOUS_USER_ID,
      metadata: {
        stackUserId: ANONYMOUS_USER_ID,
        plan: "pro",
        app: "cmux",
        billingInterval: "month",
      },
      subscription_data: {
        metadata: {
          stackUserId: ANONYMOUS_USER_ID,
          plan: "pro",
          app: "cmux",
          billingInterval: "month",
        },
      },
      allow_promotion_codes: true,
      customer_email: undefined,
      success_url:
        "https://cmux.test/api/billing/complete?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=cmux",
      cancel_url: "https://cmux.test/pricing?billing=cancelled&interval=month",
    });
    expect(captureBillingCheckoutStarted).toHaveBeenCalledTimes(1);
    expect(captureBillingCheckoutStarted).toHaveBeenCalledWith({
      sessionId: CHECKOUT_SESSION_ID,
      subject: { scope: "user", stackUserId: ANONYMOUS_USER_ID },
      plan: "pro",
      billingInterval: "month",
    });
  });

  test("does not capture checkout analytics when Stripe returns no session id", async () => {
    stripeConfigured = true;
    stripeSessionResponse = {
      url: "https://checkout.stripe.com/c/session",
    };
    userResponses = [null, anonymousUser];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=error",
    );
    expect(captureBillingCheckoutStarted).not.toHaveBeenCalled();
  });

  test("bounds Stack Auth failures before creating a checkout", async () => {
    stripeConfigured = true;
    stackAuthUnavailable = true;

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=error",
    );
    expect(createStripeSession).not.toHaveBeenCalled();
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
      metadata: { billingInterval: "year" },
      subscription_data: { metadata: { billingInterval: "year" } },
      cancel_url: "https://cmux.test/pricing?billing=cancelled&interval=year",
    });
    expect(captureBillingCheckoutStarted).toHaveBeenCalledTimes(1);
    expect(captureBillingCheckoutStarted).toHaveBeenCalledWith({
      sessionId: CHECKOUT_SESSION_ID,
      subject: { scope: "user", stackUserId: SIGNED_IN_USER_ID },
      plan: "pro",
      billingInterval: "year",
    });
  });

  test("routes a past_due customer to the billing portal", async () => {
    stripeConfigured = true;
    stripeCustomerRows = [{ id: "cus_past_due" }];
    stripeSubscriptionRows = [{
      id: "sub_past_due",
      status: "past_due",
      cancelAtPeriodEnd: false,
    }];
    stripeActiveSubscriptionRows = stripeSubscriptionRows;
    userResponses = [{ ...signedInUser, clientReadOnlyMetadata: { cmuxPlan: "pro" } }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/api/billing/portal",
    );
    expect(createStripeSession).not.toHaveBeenCalled();
  });

  test("reuses the Stripe customer for a terminally canceled Pro checkout", async () => {
    stripeConfigured = true;
    stripeCustomerRows = [{ id: "cus_canceled" }];
    stripeSubscriptionRows = [{
      id: "sub_canceled",
      status: "canceled",
      cancelAtPeriodEnd: false,
    }];
    stripeActiveSubscriptionRows = [];
    userResponses = [{ ...signedInUser, clientReadOnlyMetadata: {} }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/checkout"),
    );

    expect(response.headers.get("location")).toBe(
      "https://checkout.stripe.com/c/session",
    );
    expect(createStripeSession).toHaveBeenCalledTimes(1);
    expect(createdStripeSessions[0]).toMatchObject({
      customer: "cus_canceled",
      customer_email: undefined,
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
    expect(resolveTeamPrice).toHaveBeenCalledWith("month");
    expect(createStripeCustomer).toHaveBeenCalledWith({
      name: "Signed Team",
      metadata: { stackTeamId: TEAM_ID, app: "cmux" },
    });
    expect(insertedStripeCustomers).toContainEqual({
      id: "cus_team",
      stackUserId: SIGNED_IN_USER_ID,
      stackTeamId: TEAM_ID,
      email: null,
    });
    expect(createdStripeSessions[0]).toMatchObject({
      mode: "subscription",
      line_items: [
        {
          price: "price_team_month",
          quantity: 2,
          adjustable_quantity: { enabled: true, minimum: 1 },
        },
      ],
      customer: "cus_team",
      client_reference_id: TEAM_ID,
      metadata: {
        stackTeamId: TEAM_ID,
        plan: "team",
        app: "cmux",
        billingInterval: "month",
      },
      subscription_data: {
        metadata: {
          stackTeamId: TEAM_ID,
          plan: "team",
          app: "cmux",
          billingInterval: "month",
        },
      },
      allow_promotion_codes: true,
      success_url:
        "https://cmux.test/api/billing/complete?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=cmux",
      cancel_url: "https://cmux.test/pricing?billing=cancelled&interval=month",
    });
    expect(captureBillingCheckoutStarted).toHaveBeenCalledTimes(1);
    expect(captureBillingCheckoutStarted).toHaveBeenCalledWith({
      sessionId: CHECKOUT_SESSION_ID,
      subject: { scope: "team", stackTeamId: TEAM_ID },
      plan: "team",
      billingInterval: "month",
    });
  });

  test("uses yearly Stripe price for annual Team checkout", async () => {
    stripeConfigured = true;
    signedInUser.selectedTeam = teamCustomer;
    userResponses = [signedInUser];

    await GET(
      new NextRequest(
        "https://cmux.test/api/billing/checkout?plan=team&interval=year",
      ),
    );

    expect(resolveTeamPrice).toHaveBeenCalledWith("year");
    expect(createdStripeSessions[0]).toMatchObject({
      line_items: [{ price: "price_team_year", quantity: 2 }],
      metadata: { billingInterval: "year" },
      subscription_data: { metadata: { billingInterval: "year" } },
      cancel_url: "https://cmux.test/pricing?billing=cancelled&interval=year",
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

  test("rejects unknown checkout intervals", async () => {
    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/checkout?plan=team&interval=yearly",
      ),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=invalid_plan",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createStripeSession).not.toHaveBeenCalled();
  });
});
