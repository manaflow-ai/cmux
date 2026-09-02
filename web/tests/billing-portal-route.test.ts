import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { stripeCustomers, stripeSubscriptions } from "../db/schema";
import { withAccountMutationLeaseSupport } from
  "./helpers/account-mutation-db-mock";

const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const stripeModule = await import("../services/billing/stripe");

const signedInUser = {
  id: "user-pro",
  isAnonymous: false,
  isRestricted: false,
  primaryEmail: null as string | null,
  primaryEmailVerified: false,
  clientReadOnlyMetadata: {} as Record<string, unknown>,
  selectedTeam: null as null | { id: string; displayName?: string },
  listTeams: mock(async () => [] as Array<{ id: string; displayName?: string }>),
  update: mock(async () => undefined),
};
const anonymousUser = {
  id: "anonymous-pro",
  isAnonymous: true,
  clientReadOnlyMetadata: {},
  update: mock(async () => undefined),
};

let stackConfigured = true;
let stripeConfigured = true;
let returnNullUser: unknown = signedInUser;
let anonymousIfExistsUser: unknown = null;
let customerRows: { id: string }[] = [{ id: "cus_123" }];
let stripeSubscriptionRows: Array<{
  id: string;
  raw?: Record<string, unknown> | null;
}> = [];

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
  cloudDb: () => withAccountMutationLeaseSupport({
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

const actualErrorsModule = await import("../services/errors");
mock.module("../services/errors", () => ({
  ...actualErrorsModule,
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
    stripeSubscriptionRows = [{
      id: "sub_123",
      raw: { metadata: { app: "cmux", plan: "pro" } },
    }];
    signedInUser.selectedTeam = null;
    signedInUser.isAnonymous = false;
    signedInUser.isRestricted = false;
    signedInUser.primaryEmail = null;
    signedInUser.primaryEmailVerified = false;
    signedInUser.clientReadOnlyMetadata = {};
    signedInUser.listTeams.mockClear();
    getUser.mockClear();
    mockImplementation(signedInUser.update, async () => undefined);
    signedInUser.update.mockClear();
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

  test("opens a valid Stripe portal when metadata reconciliation would fail", async () => {
    signedInUser.primaryEmail = "pro@example.com";
    signedInUser.primaryEmailVerified = true;
    signedInUser.isAnonymous = false;
    signedInUser.isRestricted = false;
    mockImplementation(signedInUser.update, async () => {
      throw new Error("metadata update unavailable");
    });

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://billing.stripe.com/session/test",
    );
    expect(createPortalSession).toHaveBeenCalled();
  });

  test("does not open the Stripe portal for a Founder-only entitlement", async () => {
    signedInUser.clientReadOnlyMetadata = { cmuxVmPlan: "founders" };
    stripeSubscriptionRows = [{
      id: "sub_founder_only",
      raw: { metadata: { founders_edition: "true" } },
    }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=unavailable",
    );
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("keeps the portal available when a Founder also has a real Stripe subscription", async () => {
    signedInUser.clientReadOnlyMetadata = { cmuxVmPlan: "founders" };
    stripeSubscriptionRows = [{ id: "sub_founder_pro" }];

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
  });

  test("App Store portal block redirects to the direct dev-backend origin", async () => {
    const previousTransport = process.env.CMUX_DEV_BACKEND_TRANSPORT;
    const previousOrigin = process.env.CMUX_WWW_ORIGIN;
    const previousHost = process.env.CMUX_DEV_BACKEND_TAILSCALE_HOST;
    process.env.CMUX_DEV_BACKEND_TRANSPORT = "direct";
    process.env.CMUX_DEV_BACKEND_TAILSCALE_HOST = "cmux-dev-backend-1.tail137216.ts.net";
    process.env.CMUX_WWW_ORIGIN = "https://cmux-dev-backend-1.tail137216.ts.net:3916/";
    try {
      const response = await GET(
        new NextRequest(
          "https://0.0.0.0:3916/api/billing/portal?interval=year&cmux_distribution=appstore&cmux_scheme=cmux",
        ),
      );

      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toBe(
        "https://cmux-dev-backend-1.tail137216.ts.net:3916/app-pricing?cmux_app=1&cmux_distribution=appstore&billing=unavailable&interval=year",
      );
    } finally {
      if (previousTransport === undefined) delete process.env.CMUX_DEV_BACKEND_TRANSPORT;
      else process.env.CMUX_DEV_BACKEND_TRANSPORT = previousTransport;
      if (previousOrigin === undefined) delete process.env.CMUX_WWW_ORIGIN;
      else process.env.CMUX_WWW_ORIGIN = previousOrigin;
      if (previousHost === undefined) delete process.env.CMUX_DEV_BACKEND_TAILSCALE_HOST;
      else process.env.CMUX_DEV_BACKEND_TAILSCALE_HOST = previousHost;
    }
  });

  test("blocks direct portal requests from the iOS App Store distribution", async () => {
    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/portal?interval=year&cmux_distribution=appstore&cmux_scheme=cmux",
      ),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/app-pricing?cmux_app=1&cmux_distribution=appstore&billing=unavailable&interval=year",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(createPortalSession).not.toHaveBeenCalled();
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

  test("opens the Team customer portal when scope is team", async () => {
    signedInUser.selectedTeam = { id: "team-pro", displayName: "Team Pro" };
    customerRows = [{ id: "cus_team" }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal?scope=team"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://billing.stripe.com/session/test",
    );
    expect(createPortalSession).toHaveBeenCalledWith({
      customer: "cus_team",
      return_url: "https://cmux.test/dashboard/billing",
    });
  });

  test("falls back to user scope when Team scope is requested without a billing team", async () => {
    customerRows = [{ id: "cus_user" }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal?scope=team"),
    );

    expect(response.status).toBe(302);
    expect(createPortalSession).toHaveBeenCalledWith({
      customer: "cus_user",
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

  test("redirects users without a Stripe customer row to billing unavailable", async () => {
    customerRows = [];
    stripeSubscriptionRows = [];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=unavailable",
    );
    expect(captureBillingError).not.toHaveBeenCalled();
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("captures missing customer rows for Stripe-managed users and redirects unavailable", async () => {
    customerRows = [];
    stripeSubscriptionRows = [{ id: "sub_123" }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=unavailable",
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
