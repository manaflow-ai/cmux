import { describe, expect, mock, test } from "bun:test";
import { renderToReadableStream, renderToStaticMarkup } from "react-dom/server";
import { NextIntlClientProvider } from "next-intl";
import { loadMessages } from "../i18n/messages";
import { locales, type Locale } from "../i18n/routing";
import type { ReactNode } from "react";

let redirected = "";
let authorization: "ready" | "unavailable" | "pending" = "ready";
mock.module("next/navigation", () => ({ redirect: (target: string) => { redirected = target; } }));
mock.module("@/i18n/navigation", () => ({
  Link: ({ href, children }: { href: string; children: ReactNode }) => <a href={href}>{children}</a>,
  usePathname: () => "/dashboard/mobile-devices",
  useRouter: () => ({ refresh() {} }),
  getPathname: ({ locale, href }: { locale: string; href: string }) => `${locale === "en" ? "" : `/${locale}`}${href}`,
}));
mock.module("next-intl/server", () => ({
  getTranslations: async ({ locale, namespace }: { locale: Locale; namespace: string }) => {
    const catalog = await loadMessages(locale);
    const messages = namespace === "authError" ? catalog.authError as Record<string, string> : (catalog.dashboard as Record<string, Record<string, string>>).mobileDevices!;
    return (key: string) => messages[key]!;
  },
}));
mock.module("@/app/lib/stack", () => ({ isStackConfigured: () => true }));
mock.module("@/app/lib/dashboard-auth", () => ({
  dashboardAuthorizationSignInHref: (_locale: string, path: string) => `/handler/sign-in?after=${path}`,
  loadDashboardSection: async () => authorization === "pending" ? new Promise(() => {}) : authorization === "unavailable" ? { kind: "unavailable" } : { kind: "ready", user: { id: "fixture-user" } },
}));
mock.module("../app/[locale]/dashboard/dashboard-team-scope", () => ({ useDashboardTeamScope: () => ({ status: "ready", selected: { id: "fixture-team", name: "Fixture team" }, teams: [{ id: "fixture-team", name: "Fixture team" }], switchTeam: async () => {} }) }));
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({}),
  useUser: () => ({ selectedTeam: { id: "fixture-team" }, useTeams: () => [{ id: "fixture-team", displayName: "Personal" }] }),
}));
const { default: MobileDevicesPage } = await import("../app/[locale]/dashboard/mobile-devices/page");
const { MobileDevicesDashboard } = await import("../app/[locale]/dashboard/mobile-devices/mobile-devices-dashboard");
const { default: LegacyDevicesPage } = await import("../app/[locale]/dashboard/iroh/page");
const { DashboardShell } = await import("../app/[locale]/dashboard/dashboard-shell");

describe("mobile devices dashboard", () => {
  test("uses the dashboard-wide team scope instead of rendering a page picker", async () => {
    const messages = await loadMessages("en");
    const html = renderToStaticMarkup(
      <NextIntlClientProvider locale="en" messages={messages}>
        <MobileDevicesDashboard userId="fixture-user" />
      </NextIntlClientProvider>,
    );
    expect(html).toContain("Fixture team");
    expect(html).toContain("Team: Fixture team");
    expect(html).not.toContain("Team scope active");
    expect(html).not.toContain("mobile-devices-team");
    expect(html).not.toContain("<select");
  });

  test("renders the header while private authorization is still pending", async () => {
    authorization = "pending";
    try {
      const page = await MobileDevicesPage({ params: Promise.resolve({ locale: "en" }) });
      const html = renderToStaticMarkup(page);
      expect(html).toContain("Mobile devices");
      expect(html).toContain('data-testid="dashboard-section-skeleton"');
    } finally { authorization = "ready"; }
  });
  test("failed authorization renders an actionable recovery link", async () => {
    authorization = "unavailable";
    try {
      const page = await MobileDevicesPage({ params: Promise.resolve({ locale: "en" }) });
      const stream = await renderToReadableStream(page);
      await stream.allReady;
      const html = await new Response(stream).text();
      expect(html).toContain('data-testid="dashboard-auth-recovery"');
      expect(html).toContain("/handler/sign-in?after=/dashboard/mobile-devices");
      expect(html).not.toContain("Retrying");
    } finally { authorization = "ready"; }
  });

  test.each(locales)("renders product naming and navigation in %s", async locale => {
    const messages = await loadMessages(locale);
    const page = await MobileDevicesPage({ params: Promise.resolve({ locale }) });
    const stream = await renderToReadableStream(<NextIntlClientProvider locale={locale} messages={messages}><DashboardShell vaultEnabled={false}>{page}</DashboardShell></NextIntlClientProvider>);
    await stream.allReady;
    const html = await new Response(stream).text();
    expect(html).toContain('href="/dashboard/mobile-devices"');
    expect(html).toContain('data-testid="mobile-devices-dashboard"');
    expect(html).not.toMatch(/iroh|Stack|Cloudflare|Durable Object/i);
    const title = (messages.dashboard as Record<string, Record<string, string>>).mobileDevices!.title!;
    expect(html).toContain(title);
  });
  test.each(["en", "ja", "ar"])("redirects saved URLs in %s", async locale => {
    await LegacyDevicesPage({ params: Promise.resolve({ locale }) });
    expect(redirected).toBe(`${locale === "en" ? "" : `/${locale}`}/dashboard/mobile-devices`);
  });
});
