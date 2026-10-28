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
  clientReadOnlyMetadata: {},
  selectedTeam: null as null | { id: string; displayName?: string },
  listTeams: mock(async () => [] as Array<{ id: string; displayName?: string }>),
  // Admin of any team it selects; legacy `?scope=team` requires team admin.
  hasPermission: mock(async () => true),
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
let stripeSubscriptionRows: Array<Record<string, unknown>> = [];

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
  promoteStackUserFromAnonymousViaApi: async () => undefined,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () => withAccountMutationLeaseSupport({
    select: () => ({
      from: (table: unknown) => ({
        where: () => {
          const rows = table === stripeCustomers ? customerRows : table === stripeSubscriptions ? stripeSubscriptionRows : [];
          return Object.assign(Promise.resolve(rows), {
            limit: async () => rows,
            orderBy: () => ({ limit: async () => rows }),
          });
        },
      }),
    }),
  }),
}));

// The Stripe side of a past-due subscription for the payment method return.
// The return token is signed with the Stripe secret.
process.env.STRIPE_SECRET_KEY ||= "sk_test_unit";
let customerDefaultPaymentMethod: string | null = null;
let providerSubscriptions: Array<Record<string, unknown>> = [];
let openInvoices: Array<{ id: string; subscription: string; status: string; created: number; hosted_invoice_url?: string }> = [];
let invoicePaymentError: Error | null = null;
const payInvoice = mock(async (id: string, _params?: unknown) => {
  if (invoicePaymentError) throw invoicePaymentError;
  const invoice = openInvoices.find((candidate) => candidate.id === id)!;
  invoice.status = "paid";
  const subscription = providerSubscriptions.find((candidate) => candidate.id === invoice.subscription)!;
  subscription.status = "active";
  return { id, status: "paid" };
});

const resolvePersonalPlanSwitchPortalConfiguration = mock(async () => "bpc_switch");
mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  resolvePersonalPlanSwitchPortalConfiguration,
  isStripeBillingConfigured: () => stripeConfigured,
  stripe: () => ({
    billingPortal: {
      sessions: {
        create: createPortalSession,
      },
    },
    customers: {
      retrieve: async () => ({ id: "cus_123", invoice_settings: { default_payment_method: customerDefaultPaymentMethod } }),
    },
    subscriptions: {
      list: async (params: { status: string }) => ({
        data: providerSubscriptions.filter((subscription) => subscription.status === params.status),
      }),
      retrieve: async (id: string) => ({ ...providerSubscriptions.find((subscription) => subscription.id === id) }),
      update: async (id: string) => ({ id }),
    },
    invoices: {
      list: async (params: { subscription: string; status: string }) => ({
        data: openInvoices.filter((invoice) => invoice.subscription === params.subscription && invoice.status === params.status),
      }),
      retrieve: async (id: string) => ({ ...openInvoices.find((invoice) => invoice.id === id) }),
      pay: payInvoice,
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
    stripeSubscriptionRows = [];
    signedInUser.selectedTeam = null;
    signedInUser.listTeams.mockClear();
    getUser.mockClear();
    signedInUser.update.mockClear();
    anonymousUser.update.mockClear();
    createPortalSession.mockClear();
    createPortalSession.mockResolvedValue({
      url: "https://billing.stripe.com/session/test",
    });
    captureBillingError.mockClear();
    customerDefaultPaymentMethod = null;
    providerSubscriptions = [];
    payInvoice.mockClear();
    openInvoices = [];
    invoicePaymentError = null;
  });

  /** The completion link the update flow gave Stripe for the current customer. */
  async function completionURL(): Promise<string> {
    await GET(new NextRequest("https://cmux.test/api/billing/portal?flow=payment_method_update"));
    const params = createPortalSession.mock.calls.at(-1)?.[0] as {
      flow_data: { after_completion: { redirect: { return_url: string } } };
    };
    createPortalSession.mockClear();
    return params.flow_data.after_completion.redirect.return_url;
  }

  function pastDuePro() {
    customerDefaultPaymentMethod = "pm_new";
    providerSubscriptions = [{
      id: "sub_pro", status: "past_due", metadata: { app: "cmux", plan: "pro" }, default_payment_method: "pm_declined",
    }];
    openInvoices = [{ id: "in_failed", subscription: "sub_pro", status: "open", created: 1 }];
  }

  test("opens the portal's card form; saving returns through recovery, leaving returns to the dashboard", async () => {
    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal?flow=payment_method_update"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("https://billing.stripe.com/session/test");
    const params = createPortalSession.mock.calls[0]?.[0] as {
      customer: string;
      return_url: string;
      flow_data: { type: string; after_completion: { type: string; redirect: { return_url: string } } };
    };
    expect(params.customer).toBe("cus_123");
    expect(params.return_url).toBe("https://cmux.test/dashboard/billing");
    expect(params.flow_data.type).toBe("payment_method_update");
    expect(params.flow_data.after_completion.type).toBe("redirect");
    const completed = new URL(params.flow_data.after_completion.redirect.return_url);
    expect(completed.origin + completed.pathname).toBe("https://cmux.test/api/billing/portal");
    expect(completed.searchParams.get("flow")).toBe("payment_method_return");
    expect(completed.searchParams.get("token")).toMatch(/^\d+\.[a-f0-9]{64}$/);
  });

  test("pays a past-due renewal with the saved card on return and reports it", async () => {
    pastDuePro();

    const response = await GET(new NextRequest(await completionURL()));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?billing=payment_updated");
    expect(payInvoice).toHaveBeenCalledWith("in_failed", { payment_method: "pm_new" });
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  // A return link that did not come from this customer's portal session, a
  // forged cross-site link included, never charges.
  test.each([
    ["no token", "https://cmux.test/api/billing/portal?flow=payment_method_return"],
    ["a forged token", `https://cmux.test/api/billing/portal?flow=payment_method_return&token=9999999999.${"0".repeat(64)}`],
  ])("charges nothing on a return with %s", async (_label, url) => {
    pastDuePro();

    const response = await GET(new NextRequest(url));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing");
    expect(payInvoice).not.toHaveBeenCalled();
  });

  test("reports a declined replacement card on return", async () => {
    pastDuePro();
    invoicePaymentError = Object.assign(new Error("Your card was declined."), { type: "StripeCardError" });

    const response = await GET(new NextRequest(await completionURL()));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?billing=payment_failed");
  });

  test("sends a card that needs 3D Secure to Stripe's hosted invoice page", async () => {
    pastDuePro();
    openInvoices[0]!.hosted_invoice_url = "https://invoice.stripe.com/i/in_failed";
    invoicePaymentError = Object.assign(new Error("The invoice payment requires additional action."), {
      type: "StripeCardError", code: "invoice_payment_intent_requires_action",
    });

    const response = await GET(new NextRequest(await completionURL()));

    expect(response.headers.get("location")).toBe("https://invoice.stripe.com/i/in_failed");
  });

  test("keeps a Stripe outage during recovery on the dashboard with an error banner", async () => {
    pastDuePro();
    invoicePaymentError = Object.assign(new Error("Stripe is unavailable"), { type: "StripeAPIError" });

    const response = await GET(new NextRequest(await completionURL()));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?billing=error");
    expect(captureBillingError).toHaveBeenCalled();
  });

  test("returns to the dashboard without a banner when nothing was due", async () => {
    customerDefaultPaymentMethod = "pm_new";
    providerSubscriptions = [{ id: "sub_pro", status: "active", metadata: { app: "cmux", plan: "pro" } }];

    const response = await GET(new NextRequest(await completionURL()));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing");
    expect(payInvoice).not.toHaveBeenCalled();
  });

  test("sends a payment method update without a Stripe customer to pricing", async () => {
    customerRows = [];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal?flow=payment_method_update"),
    );

    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?billing=unavailable");
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("opens Stripe's plan switch flow on the active Pro subscription for flow=switch_plan", async () => {
    stripeSubscriptionRows = [{
      id: "sub_pro", status: "active", cancelAtPeriodEnd: false, plan: "pro",
      raw: { items: { data: [{ price: { lookup_key: "cmux-pro-monthly-50" } }] } },
    }];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=max"),
    );

    expect(response.status).toBe(302);
    expect(createPortalSession).toHaveBeenCalledWith({
      customer: "cus_123",
      return_url: "https://cmux.test/dashboard/billing",
      configuration: "bpc_switch",
      flow_data: {
        type: "subscription_update",
        subscription_update: { subscription: "sub_pro" },
      },
    });
  });

  // A switch link the hosted portal cannot honor goes where the switch can
  // happen: checkout when there is no subscription to switch, the dashboard
  // dialog when the subscription needs the interval-aware in-app switch.
  test("sends a switch link with no subscription to switch to checkout", async () => {
    stripeSubscriptionRows = [];

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=max&cmux_source=pricing"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("https://cmux.test/api/billing/checkout?plan=max&cmux_source=pricing");
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("sends a granted account without a Stripe customer from a switch link to checkout", async () => {
    customerRows = [];
    returnNullUser = { ...signedInUser, clientReadOnlyMetadata: { cmuxVmPlan: "pro" } };

    const response = await GET(new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=max"));

    expect(response.headers.get("location")).toBe("https://cmux.test/api/billing/checkout?plan=max");
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("sends a switch link for a price the switch portal does not list to the dashboard switch", async () => {
    stripeSubscriptionRows = [{
      id: "sub_pro", status: "active", cancelAtPeriodEnd: false, plan: "pro",
      raw: { items: { data: [{ price: { lookup_key: "cmux-pro-yearly-288" } }] } },
    }];
    const response = await GET(new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=max"));
    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?change=max");
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("sends a switch link for a yearly subscription to the dashboard switch", async () => {
    stripeSubscriptionRows = [{
      id: "sub_pro_yearly", status: "active", cancelAtPeriodEnd: false, plan: "pro",
      raw: {
        items: {
          data: [{
            price: {
              lookup_key: "cmux-pro-yearly-480",
              recurring: { interval: "year" },
            },
          }],
        },
      },
    }];

    const response = await GET(new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=max"));

    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?change=max");
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  test("sends a lifetime Founder's switch link to Max checkout, never the plan switch flow", async () => {
    stripeSubscriptionRows = [{ id: "sub_founder", status: "active", plan: "pro", raw: { metadata: { founders_edition: "true" } } }];
    const response = await GET(new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=max"));
    expect(response.headers.get("location")).toBe("https://cmux.test/api/billing/checkout?plan=max");
    expect(createPortalSession).not.toHaveBeenCalled();
  });

  // Founder's Edition already includes Pro. A founder leaving Max ends the Max
  // subscription in the dashboard instead of paying for Pro.
  test("never moves a Founder's Max subscription onto paid Pro through the switch flow", async () => {
    stripeSubscriptionRows = [
      {
        id: "sub_max", status: "active", cancelAtPeriodEnd: false, plan: "max",
        raw: { items: { data: [{ price: { lookup_key: "cmux-max-monthly-200", recurring: { interval: "month" } } }] } },
      },
      { id: "sub_founder", status: "active", plan: "pro", raw: { metadata: { founders_edition: "true" } } },
    ];
    const response = await GET(new NextRequest("https://cmux.test/api/billing/portal?flow=switch_plan&plan=pro"));
    expect(response.headers.get("location")).toBe("https://cmux.test/dashboard/billing?change=pro");
    expect(createPortalSession).not.toHaveBeenCalled();
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
      return_url: "https://cmux.test/dashboard/billing",
    });
    expect(getUser).toHaveBeenCalledWith({ or: "return-null" });
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
      return_url: "https://cmux.test/dashboard/billing",
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
    // Legacy implicit team: the portal returns to that team's billing view.
    expect(createPortalSession).toHaveBeenCalledWith({
      customer: "cus_team",
      return_url: "https://cmux.test/dashboard/billing?team=team-pro",
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
      return_url: "https://cmux.test/dashboard/billing",
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
    stripeSubscriptionRows = [{ id: "sub_123", status: "active", plan: "pro", scope: "user" }];

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
