import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";
import { createTranslator, type AbstractIntlMessages } from "use-intl/core";

import enMessages from "../messages/en.json";
import {
  createScreenQueryClient,
  renderDashboardScreen,
} from "./helpers/dashboard-spa-render";
import {
  createTestflightUser,
  testflightUserEligibility,
} from "./helpers/testflight-user";
import { procedureResponse } from "./helpers/dashboard-procedure";

let stackConfigured = true;
let currentUser: ReturnType<typeof createTestflightUser> | null = null;
let ascConfigured = true;
let ascFailure: Error | null = null;
let status = { enrolled: false } as { enrolled: boolean; state?: string };

const getUser = mock(async () => currentUser);
const isTestflightEligible = mock(async (user: unknown) =>
  (user as { id?: string }).id === currentUser?.id
    ? (testflightUserEligibility(currentUser) ?? false)
    : false,
);
const billingProModule = await import("../services/billing/pro");
const ascFetch = mock(async (path: unknown) => {
  if (ascFailure) throw ascFailure;
  if (String(path).startsWith("/v1/betaTesters?")) {
    return {
      data: [
        {
          type: "betaTesters",
          id: "tester_123",
          attributes: status.state ? { state: status.state } : {},
        },
      ],
    };
  }
  if (String(path).includes("/betaGroups")) {
    return {
      data: status.enrolled
        ? [{ type: "betaGroups", id: PRO_TESTFLIGHT_GROUP_ID }]
        : [],
    };
  }
  return {};
});
const captureAscError = mock(() => undefined);

// The screen uses the client `useTranslations`; mock it with the real ICU
// translator over the English catalog and export the full client surface.
mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) =>
    createTranslator({
      locale: "en",
      messages: enMessages as unknown as AbstractIntlMessages,
      namespace: namespace as never,
      timeZone: "UTC",
    }),
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../services/asc/client", () => ({
  AscApiError: class AscApiError extends Error {},
  AscConfigurationError: class AscConfigurationError extends Error {},
  AscNetworkError: class AscNetworkError extends Error {},
  ascFetch,
  isAscConfigured: () => ascConfigured,
}));

mock.module("../services/errors", () => ({
  captureAscError,
  captureBillingError: mock(() => undefined),
}));

mock.module("../services/billing/pro", () => ({
  ...billingProModule,
  isTestflightEligible,
}));

const { PRO_TESTFLIGHT_GROUP_ID } = await import("../services/asc/testflight");
const { accountRouter } = await import("../orpc/server/dashboard/account");
const GET = (request: Request) => procedureResponse(accountRouter.testflight, undefined, request);
const { TestflightScreen } = await import("../dashboard-app/screens/testflight/testflight-screen");
const { testflightQuery } = await import("../dashboard-app/queries/testflight");
const { planQuery } = await import("../dashboard-app/queries/billing");

function testflightRequest() {
  return new NextRequest("https://cmux.test/api/testflight");
}

describe("dashboard.account.testflight", () => {
  beforeEach(resetFixtures);

  test("returns 401 without a signed-in user", async () => {
    currentUser = null;
    const response = await GET(testflightRequest());
    expect(response.status).toBe(401);
  });

  test("returns eligibility, the normalized email, and enrollment", async () => {
    status = { enrolled: true, state: "INVITED" };
    const response = await GET(testflightRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      eligible: true,
      email: "pro@example.com",
      status: { enrolled: true, state: "INVITED" },
    });
  });

  test("does not call App Store Connect for an ineligible user", async () => {
    currentUser = createTestflightUser({ eligible: false });
    expect(await (await GET(testflightRequest())).json()).toEqual({
      eligible: false,
      email: "pro@example.com",
      status: { enrolled: false },
    });
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("reports unavailable when App Store Connect is not configured", async () => {
    ascConfigured = false;
    const body = await (await GET(testflightRequest())).json();
    expect(body.status).toEqual({ enrolled: false, unavailable: true });
  });

  test("captures an App Store Connect failure and reports unavailable", async () => {
    ascFailure = new Error("asc down");
    const body = await (await GET(testflightRequest())).json();
    expect(body.status).toEqual({ enrolled: false, unavailable: true });
    expect(captureAscError).toHaveBeenCalledTimes(1);
  });

  test("rechecks eligibility on every request", async () => {
    const eligible = await (await GET(testflightRequest())).json();
    currentUser = createTestflightUser({ eligible: false });
    const ineligible = await (await GET(testflightRequest())).json();
    expect(eligible.eligible).toBe(true);
    expect(ineligible.eligible).toBe(false);
    expect(isTestflightEligible).toHaveBeenCalledTimes(2);
  });
});

describe("dashboard TestFlight screen", () => {
  beforeEach(resetFixtures);

  test("paints the page header and a section skeleton before the private content", async () => {
    const html = await renderDashboardScreen({
      url: "/dashboard/testflight",
      queryClient: createScreenQueryClient(),
      render: () => <TestflightScreen />,
    });

    expect(html).toContain("iOS TestFlight");
    expect(html).toContain('data-testid="dashboard-section-skeleton"');
    expect(html).not.toContain("/api/testflight");
  });

  test("a Free viewer gets the Requires Pro panel with a checkout that returns to TestFlight", async () => {
    currentUser = createTestflightUser({ eligible: false });

    const html = await renderTestflightPage({}, { planId: "free", isPro: false, billingManagement: "none" });

    expect(html).toContain('data-testid="requires-pro"');
    expect(html).toContain("The cmux iOS app is part of Pro.");
    expect(html).toContain("returnTo=%2Fdashboard%2Ftestflight");
    expect(html).toContain("plan=pro");
    // The panel above already explains it; no second "subscription required" card.
    expect(html).not.toContain("Subscription required");
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("a paid plan without TestFlight explains it and links to Plan & billing", async () => {
    currentUser = createTestflightUser({ eligible: false });

    const html = await renderTestflightPage({}, { planId: "go", isPro: true, billingManagement: "stripe" });

    expect(html).not.toContain('data-testid="requires-pro"');
    expect(html).toContain("Subscription required");
    expect(html).toContain('href="/dashboard/billing"');
  });

  test("after checkout, TestFlight shows the welcome line instead of the upgrade prompt", async () => {
    const html = await renderTestflightPage({ welcome: "pro" }, { planId: "pro", isPro: true, billingManagement: "stripe" });
    expect(html).toContain('data-testid="plan-welcome"');
    expect(html).not.toContain('data-testid="requires-pro"');
  });

  test("a stale welcome link does not hide the upgrade prompt from a Free viewer", async () => {
    const html = await renderTestflightPage({ welcome: "pro" }, { planId: "free", isPro: false, billingManagement: "none" });
    expect(html).toContain('data-testid="requires-pro"');
    expect(html).not.toContain('data-testid="plan-welcome"');
  });

  test("renders eligible not enrolled state with join form", async () => {
    const html = await renderTestflightPage();

    expect(html).toContain("Join the iOS beta");
    expect(html).toContain("Apple will send a TestFlight invite to pro@example.com");
    expect(html).toContain('action="/api/testflight"');
    expect(html).toContain('name="action" value="join"');
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesters?filter[email]=pro%40example.com&limit=1",
    );
  });

  test("renders enrolled state with status and leave form", async () => {
    status = { enrolled: true, state: "INVITED" };

    const html = await renderTestflightPage();

    expect(html).toContain("You are enrolled");
    expect(html).toContain("INVITED");
    expect(html).toContain("Access ends automatically if your subscription lapses.");
    expect(html).toContain('name="action" value="leave"');
  });

  test("renders the unavailable state when enrollment cannot be read", async () => {
    ascConfigured = false;

    const html = await renderTestflightPage();

    expect(html).toContain(enMessages.dashboard.testflight.unavailable.title);
    expect(html).not.toContain("/api/testflight");
  });

  test("asks for an email when the account has none", async () => {
    currentUser = { ...createTestflightUser(), primaryEmail: "  " };
    Object.defineProperty(currentUser, Symbol.for("cmux.tests.testflightEligibility"), { value: true });

    const html = await renderTestflightPage();

    expect(html).toContain(enMessages.dashboard.testflight.needsEmail.title);
    expect(ascFetch).not.toHaveBeenCalled();
  });

  for (const [testflight, message] of [
    ["joined", "Apple will email your TestFlight invite shortly."],
    ["left", "You have left the iOS TestFlight group."],
    ["error", "TestFlight could not be updated. Try again shortly."],
    ["ineligible", "An active personal Pro subscription is required for iOS TestFlight."],
    ["needs_email", "Add a verified primary email before joining iOS TestFlight."],
    ["unavailable", "TestFlight enrollment is not available right now."],
  ] as const) {
    test(`renders ${testflight} banner`, async () => {
      const html = await renderTestflightPage({ testflight });

      expect(html).toContain(message);
    });
  }
});

function resetFixtures() {
  stackConfigured = true;
  currentUser = createTestflightUser();
  ascConfigured = true;
  ascFailure = null;
  status = { enrolled: false };
  getUser.mockClear();
  isTestflightEligible.mockClear();
  ascFetch.mockClear();
  captureAscError.mockClear();
}

/** The API route answers from the mocked user; the screen renders that answer. */
async function renderTestflightPage(
  search: { testflight?: string; welcome?: string } = {},
  plan?: { planId: "free" | "go" | "pro" | "max"; isPro: boolean; billingManagement: "stripe" | "external" | "none" },
) {
  const response = await GET(testflightRequest());
  expect(response.status).toBe(200);
  const queryClient = createScreenQueryClient();
  queryClient.setQueryData(testflightQuery.queryKey, await response.json());
  if (plan) queryClient.setQueryData(planQuery.queryKey, plan);
  const params = new URLSearchParams(Object.entries(search).filter(([, value]) => value !== undefined) as [string, string][]);
  const query = params.size ? `?${params}` : "";
  return renderDashboardScreen({
    url: `/dashboard/testflight${query}`,
    queryClient,
    render: () => <TestflightScreen testflight={search.testflight} />,
  });
}
