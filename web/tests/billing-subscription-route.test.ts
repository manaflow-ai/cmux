import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

// Capture real implementations BY VALUE before mocking. bun's mock.module can
// mutate an already-loaded namespace in place, so delegating through copied
// function references avoids recursive mocks.
const dbClientModule = await import("../db/client");
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const stripeModule = await import("../services/billing/stripe");

const signedInUser = {
  id: "user-pro",
  isAnonymous: false,
  selectedTeam: null as null | { id: string },
  listTeams: mock(async () => [] as Array<{ id: string }>),
};
const anonymousUser = {
  id: "anonymous-pro",
  isAnonymous: true,
};

let stackConfigured = true;
let stripeConfigured = true;
let returnNullUser: unknown = signedInUser;
let anonymousIfExistsUser: unknown = null;
let subscriptionRows: { id: string }[] = [{ id: "sub_123" }];
const dbUpdates: Array<{ values: Record<string, unknown> }> = [];

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

const updateSubscription = mock(stripeSubscriptionUpdateResult);
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
      from: () => ({
        where: () => ({
          orderBy: () => ({
            limit: mock(async () => subscriptionRows),
          }),
        }),
      }),
    }),
    update: () => ({
      set: (values: Record<string, unknown>) => ({
        where: () => {
          dbUpdates.push({ values });
          return Promise.resolve();
        },
      }),
    }),
  }),
}));

mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => stripeConfigured,
  stripe: () => ({
    subscriptions: {
      update: updateSubscription,
    },
  }),
}));

const actualErrorsModule = await import("../services/errors");
mock.module("../services/errors", () => ({
  ...actualErrorsModule,
  captureBillingError,
}));

const { POST } = await import("../app/api/billing/subscription/route");

describe("billing subscription route", () => {
  beforeEach(() => {
    stackConfigured = true;
    stripeConfigured = true;
    returnNullUser = signedInUser;
    anonymousIfExistsUser = null;
    subscriptionRows = [{ id: "sub_123" }];
    dbUpdates.length = 0;
    signedInUser.selectedTeam = null;
    signedInUser.listTeams.mockClear();
    getUser.mockClear();
    updateSubscription.mockClear();
    mockImplementation(updateSubscription, stripeSubscriptionUpdateResult);
    captureBillingError.mockClear();
  });

  test("cancels the current user's active subscription at period end from a same-origin form post", async () => {
    const response = await postAction("cancel");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=cancelled",
    );
    expect(updateSubscription).toHaveBeenCalledWith("sub_123", {
      cancel_at_period_end: true,
    });
    expect(dbUpdates).toHaveLength(1);
    expect(dbUpdates[0].values.cancelAtPeriodEnd).toBe(true);
    expect(dbUpdates[0].values.raw).toMatchObject({
      id: "sub_123",
      cancel_at_period_end: true,
    });
  });

  test("rejects cross-site form posts before auth, Stripe, or DB writes", async () => {
    const response = await postAction("cancel", {
      origin: "https://evil.example",
      secFetchSite: "cross-site",
    });

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=error",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(updateSubscription).not.toHaveBeenCalled();
    expect(dbUpdates).toHaveLength(0);
    expect(captureBillingError).not.toHaveBeenCalled();
  });

  test("redirects junk actions to the error banner without Stripe or DB writes", async () => {
    const response = await postAction("garbage");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=error",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(updateSubscription).not.toHaveBeenCalled();
    expect(dbUpdates).toHaveLength(0);
    expect(captureBillingError).not.toHaveBeenCalled();
  });

  test("resumes a pending cancellation", async () => {
    const response = await postAction("resume");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=resumed",
    );
    expect(updateSubscription).toHaveBeenCalledWith("sub_123", {
      cancel_at_period_end: false,
    });
    expect(dbUpdates[0].values.cancelAtPeriodEnd).toBe(false);
  });

  test("cancels the current user's Team subscription from the derived billing team", async () => {
    signedInUser.selectedTeam = { id: "team-pro" };
    subscriptionRows = [{ id: "sub_team" }];

    const response = await postAction("cancel", {
      scope: "team",
      teamId: "team-pro",
    });

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=cancelled",
    );
    expect(updateSubscription).toHaveBeenCalledWith("sub_team", {
      cancel_at_period_end: true,
    });
    expect(dbUpdates[0].values.cancelAtPeriodEnd).toBe(true);
  });

  test("rejects Team subscription changes for a posted team outside the user's billing team", async () => {
    signedInUser.selectedTeam = { id: "team-a" };

    const response = await postAction("cancel", {
      scope: "team",
      teamId: "team-b",
    });

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=error",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
    expect(dbUpdates).toHaveLength(0);
  });

  test("rejects Team scope when no billing team can be derived", async () => {
    const response = await postAction("cancel", { scope: "team" });

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=error",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
  });

  test("redirects unauthenticated users to the localized dashboard sign-in path", async () => {
    returnNullUser = null;
    anonymousIfExistsUser = null;

    const response = await postAction("cancel", {
      referer: "https://cmux.test/ja/dashboard/billing",
    });
    const location = new URL(response.headers.get("location")!);
    const afterSignIn = new URL(
      location.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );

    expect(response.status).toBe(303);
    expect(location.pathname).toBe("/handler/sign-in");
    expect(afterSignIn.pathname).toBe("/handler/after-sign-in");
    expect(afterSignIn.searchParams.get("after_auth_return_to")).toBe(
      "/ja/dashboard/billing",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
  });

  test("falls back to an existing anonymous purchaser", async () => {
    returnNullUser = null;
    anonymousIfExistsUser = anonymousUser;
    subscriptionRows = [{ id: "sub_anonymous" }];

    const response = await postAction("cancel");

    expect(response.status).toBe(303);
    expect(getUser).toHaveBeenCalledTimes(2);
    expect(getUser).toHaveBeenCalledWith({ or: "return-null" });
    expect(getUser).toHaveBeenCalledWith({ or: "anonymous-if-exists[deprecated]" });
    expect(updateSubscription).toHaveBeenCalledWith("sub_anonymous", {
      cancel_at_period_end: true,
    });
  });

  test("redirects back with nosub when no active Stripe subscription exists", async () => {
    subscriptionRows = [];

    const response = await postAction("cancel");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=nosub",
    );
    expect(updateSubscription).not.toHaveBeenCalled();
    expect(captureBillingError).not.toHaveBeenCalled();
  });

  test("captures Stripe failures and redirects back with an error banner", async () => {
    mockImplementation(updateSubscription, async () => {
      throw new Error("stripe down");
    });

    const response = await postAction("cancel");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?billing=error",
    );
    expect(captureBillingError).toHaveBeenCalledWith(
      expect.objectContaining({ message: "stripe down" }),
      expect.objectContaining({
        route: "/api/billing/subscription",
        stackUserId: "user-pro",
        action: "cancel",
      }),
    );
  });
});

function postAction(
  action: string,
  options: {
    referer?: string;
    origin?: string;
    secFetchSite?: string;
    scope?: "user" | "team";
    teamId?: string;
  } = {},
) {
  const headers = new Headers({
    "content-type": "application/x-www-form-urlencoded",
    origin: options.origin ?? "https://cmux.test",
    referer: options.referer ?? "https://cmux.test/dashboard/billing",
  });
  if (options.secFetchSite) {
    headers.set("sec-fetch-site", options.secFetchSite);
  }

  const body = new URLSearchParams({ action });
  if (options.scope) body.set("scope", options.scope);
  if (options.teamId) body.set("teamId", options.teamId);

  return POST(
    new NextRequest("https://cmux.test/api/billing/subscription", {
      method: "POST",
      headers,
      body,
    }),
  );
}

function mockImplementation(
  fn: unknown,
  implementation: (...args: unknown[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}

async function stripeSubscriptionUpdateResult(id: unknown, params: unknown) {
  const updateParams = params as Record<string, unknown>;
  return {
    id,
    status: "active",
    customer: "cus_123",
    cancel_at_period_end: updateParams.cancel_at_period_end,
    items: { data: [] },
  };
}
