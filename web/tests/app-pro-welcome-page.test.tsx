import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

const proModule = await import("../services/billing/pro");

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

// bun's mock.module replaces these modules process-wide, so each mock must
// carry every export another test in the suite might import.
mock.module("next/navigation", () => ({
  redirect,
  notFound: () => {
    throw new Error("notFound");
  },
  permanentRedirect: redirect,
}));

let stackConfigured = true;
let currentUser: unknown = null;
let currentIsPro = false;

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser: async () => currentUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser: async () => currentUser } : null,
}));

mock.module("../services/billing/pro", () => ({
  ...proModule,
  resolveProPlanStatus: async () => ({
    planId: currentIsPro ? "pro" : "free",
    isPro: currentIsPro,
    billingManagement: currentIsPro ? "stripe" : "none",
  }),
}));

const { default: AppProWelcomePage } = await import("../app/app-pro-welcome/page");

const proUser = { id: "user-1", isAnonymous: false, primaryEmail: "pro@example.com" };

describe("app pro welcome page", () => {
  beforeEach(() => {
    redirect.mockClear();
    stackConfigured = true;
    currentUser = null;
    currentIsPro = false;
  });

  test("redirects to the dashboard billing page outside the cmux app", async () => {
    await expect(
      AppProWelcomePage({ searchParams: Promise.resolve({}) }),
    ).rejects.toMatchObject({ href: "/dashboard/billing" });
  });

  test("redirects a signed-out visitor even inside the cmux app", async () => {
    currentUser = null;
    await expect(
      AppProWelcomePage({ searchParams: Promise.resolve({ cmux_app: "1" }) }),
    ).rejects.toMatchObject({ href: "/dashboard/billing" });
  });

  test("redirects a signed-in non-Pro user", async () => {
    currentUser = proUser;
    currentIsPro = false;
    await expect(
      AppProWelcomePage({ searchParams: Promise.resolve({ cmux_app: "1" }) }),
    ).rejects.toMatchObject({ href: "/dashboard/billing" });
  });

  test("renders the welcome checklist for a signed-in Pro user in the cmux app", async () => {
    currentUser = proUser;
    currentIsPro = true;

    const element = await AppProWelcomePage({
      searchParams: Promise.resolve({ cmux_app: "1", appearance: "dark" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("Welcome to cmux Pro");
    expect(html).toContain("Model gateway");
    expect(html).toContain("cmux iOS app");
    expect(html).toContain('href="/dashboard/subrouter"');
    expect(html).toContain('href="/dashboard/ai-accounts"');
    expect(html).toContain('href="/dashboard/testflight"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain('data-app-pro-welcome-appearance="dark"');
    expect(redirect).not.toHaveBeenCalled();
  });
});
