import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

const redirect = mock((href: unknown) => {
  throw Object.assign(new Error("redirect"), { href });
});
let activeLocale = "en";

// bun's mock.module replaces these modules process-wide. Keep the shared
// export set complete so this file cannot break an unrelated suite.
mock.module("next/navigation", () => createNextNavigationMock(redirect));
mock.module("../app/app-pro-welcome/locale", () => ({
  getLocale: async () => activeLocale,
}));

const { default: AppProWelcomePage } = await import("../app/app-pro-welcome/page");
const AppProWelcomeLayoutModule = await import("../app/app-pro-welcome/layout");

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

  test("shows TestFlight as the current Pro benefit inside the cmux app", async () => {
    const element = await AppProWelcomePage({
      searchParams: Promise.resolve({
        cmux_app: "1",
        appearance: "dark",
        background: "#112233",
        foreground: "#ddeeff",
        accent: "#0091ff",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("Welcome to cmux Pro");
    expect(html).toContain("Pro features are still being built");
    expect(html).toContain("usage credits accumulated for every month");
    expect(html).toContain("cmux iOS app");
    expect(html).toContain(
      'href="/dashboard/testflight?cmux_open_in_browser=split-right"',
    );
    expect(html).toContain(
      'href="/dashboard/billing?cmux_open_in_browser=split-right"',
    );
    expect(html).toContain(
      'href="/dashboard?cmux_open_in_browser=split-right"',
    );
    expect(html).not.toContain('target="_blank"');
    expect(html).toContain(
      'class="mt-2 text-sm leading-5 text-muted">See your plan, invoices, and cancellation.',
    );
    expect(html).not.toContain('href="/dashboard/subrouter"');
    expect(html).not.toContain('href="/dashboard/ai-accounts"');
    expect(html).toContain('data-app-pro-welcome-appearance="dark"');
    expect(html).toContain('data-cmux-app-theme="true"');
    expect(html).toContain("--ghostty-background:#112233");
    expect(html).toContain("--ghostty-foreground:#ddeeff");
    expect(html).toContain("--cmux-product-blue:#0091ff");
    expect(html).toContain("--cmux-product-blue-on-background:#0091ff");
    expect(html).toContain("--cmux-product-blue-on-foreground:#006CBF");
  });

  test("uses the active web locale for the Pro welcome", async () => {
    activeLocale = "fr";
    try {
      const element = await AppProWelcomePage({
        searchParams: Promise.resolve({ cmux_app: "1" }),
      });
      const html = renderToStaticMarkup(element);

      expect(html).toContain("Bienvenue dans cmux Pro");
      expect(html).toContain("L’accès au cloud arrive bientôt");
      expect(html).toContain("Rejoindre la bêta iOS");
      expect(html).toContain(
        'href="/fr/dashboard/testflight?cmux_open_in_browser=split-right"',
      );
      expect(html).toContain(
        'href="/fr/dashboard/billing?cmux_open_in_browser=split-right"',
      );
      expect(html).toContain(
        'href="/fr/dashboard?cmux_open_in_browser=split-right"',
      );
      expect(html).not.toContain('target="_blank"');
    } finally {
      activeLocale = "en";
    }
  });

  test("uses the active web locale for the Pro welcome metadata", async () => {
    activeLocale = "fr";
    try {
      const generateMetadata = (
        AppProWelcomeLayoutModule as {
          generateMetadata?: () => Promise<{
            title?: unknown;
            description?: unknown;
          }>;
        }
      ).generateMetadata;
      expect(typeof generateMetadata).toBe("function");
      if (!generateMetadata) throw new Error("generateMetadata is missing");

      const metadata = await generateMetadata();

      expect(metadata.title).toBe("Bienvenue dans cmux Pro");
      expect(metadata.description).toContain("L’accès au cloud arrive bientôt");
    } finally {
      activeLocale = "en";
    }
  });
});
