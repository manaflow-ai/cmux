import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { NextIntlClientProvider } from "next-intl";
import { loadMessages } from "../i18n/messages";
import { locales, type Locale } from "../i18n/routing";
import type { ReactNode } from "react";

let redirected = "";
mock.module("next/navigation", () => ({ redirect: (target: string) => { redirected = target; } }));
mock.module("@/i18n/navigation", () => ({
  Link: ({ href, children }: { href: string; children: ReactNode }) => <a href={href}>{children}</a>,
  usePathname: () => "/dashboard/mobile-devices",
  useRouter: () => ({ refresh() {} }),
  getPathname: ({ locale, href }: { locale: string; href: string }) => `${locale === "en" ? "" : `/${locale}`}${href}`,
}));
mock.module("next-intl/server", () => ({
  getTranslations: async ({ locale }: { locale: Locale }) => {
    const catalog = await loadMessages(locale);
    const messages = (catalog.dashboard as Record<string, Record<string, string>>).mobileDevices!;
    return (key: string) => messages[key]!;
  },
}));
mock.module("@/app/lib/stack", () => ({ isStackConfigured: () => true }));
mock.module("@/app/lib/dashboard-auth", () => ({ loadDashboardSection: async () => ({ kind: "ready", user: { id: "fixture-user" } }) }));
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({}),
  useUser: () => ({ selectedTeam: { id: "fixture-team" }, useTeams: () => [{ id: "fixture-team", displayName: "Personal" }] }),
}));
const { default: MobileDevicesPage } = await import("../app/[locale]/dashboard/mobile-devices/page");
const { default: LegacyDevicesPage } = await import("../app/[locale]/dashboard/iroh/page");
const { DashboardShell } = await import("../app/[locale]/dashboard/dashboard-shell");

describe("mobile devices dashboard", () => {
  test.each(locales)("renders product naming and navigation in %s", async locale => {
    const messages = await loadMessages(locale);
    const page = await MobileDevicesPage({ params: Promise.resolve({ locale }) });
    const html = renderToStaticMarkup(<NextIntlClientProvider locale={locale} messages={messages}><DashboardShell vaultEnabled={false}>{page}</DashboardShell></NextIntlClientProvider>);
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
