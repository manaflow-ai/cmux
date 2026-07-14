import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});

// bun's mock.module replaces these modules process-wide. Keep the shared
// export set complete so this file cannot break an unrelated suite.
mock.module("next/navigation", () => createNextNavigationMock(redirect));

const { default: AppProWelcomePage } = await import("../app/app-pro-welcome/page");

describe("app pro welcome page", () => {
  test("keeps client navigation components importable after installing the navigation mock", async () => {
    const navigation = await import("next/navigation");
    const banner = await import("../app/[locale]/components/pro-welcome-banner");

    expect(typeof navigation.useRouter).toBe("function");
    expect(typeof navigation.useSearchParams).toBe("function");
    expect(typeof banner.ProWelcomeBanner).toBe("function");
  });

  test("redirects to the dashboard billing page outside the cmux app", async () => {
    await expect(
      AppProWelcomePage({ searchParams: Promise.resolve({}) }),
    ).rejects.toMatchObject({ href: "/dashboard/billing" });
  });

  test("renders the welcome checklist with dashboard links inside the cmux app", async () => {
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
  });
});
