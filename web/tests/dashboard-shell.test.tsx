import { describe, expect, mock, test } from "bun:test";
import { NextIntlClientProvider } from "next-intl";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import { loadMessages } from "../i18n/messages";
import { locales } from "../i18n/routing";

const accountControl = <span data-testid="account-control" />;
let pathname = "/dashboard/testflight";

// The shell only needs `Link` and the current pathname from the router.
mock.module("@tanstack/react-router", () => ({
  Link: ({
    to,
    children,
    ...props
  }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) => (
    <a href={to} {...props}>{children}</a>
  ),
  useLocation: () => ({ pathname }),
}));

const { DashboardShell } = await import("../dashboard-app/shell/dashboard-shell");

async function renderShell(vaultEnabled: boolean, locale = "en") {
  const messages = await loadMessages(locale as "en");
  return renderToStaticMarkup(
    <NextIntlClientProvider locale={locale} messages={messages} timeZone="UTC">
      <DashboardShell vaultEnabled={vaultEnabled} account={accountControl}>
        <p>Dashboard content</p>
      </DashboardShell>
    </NextIntlClientProvider>,
  );
}

describe("dashboard shell", () => {
  test("mounts one account control across responsive layouts", async () => {
    const html = await renderShell(true);

    expect(html.match(/data-testid="account-control"/g)).toHaveLength(1);
    // The theme toggle lives inside the account menu, not in the shell footer.
    expect(html).not.toContain("theme-control");
    expect(html).toContain('href="/dashboard/coderouter"');
    // Account group: settings, then teams, then billing. The legacy
    // Hexclave route is no longer linked.
    const settingsIndex = html.indexOf('href="/dashboard/settings"');
    const teamsIndex = html.indexOf('href="/dashboard/teams"');
    const billingIndex = html.indexOf('href="/dashboard/billing"');
    expect(settingsIndex).toBeGreaterThan(-1);
    expect(teamsIndex).toBeGreaterThan(settingsIndex);
    expect(billingIndex).toBeGreaterThan(teamsIndex);
    expect(html).not.toContain('href="/dashboard/team"');
    const menuButton = html.match(
      /<button[^>]*aria-controls="dashboard-mobile-nav"[^>]*>/,
    )?.[0];
    expect(menuButton).toContain("sm:hidden");
    const controlledNavigation = html.match(
      /<nav[^>]*id="dashboard-mobile-nav"[^>]*>/,
    )?.[0];
    expect(controlledNavigation).toContain("hidden");
    expect(html).toContain("pb-28");
    expect(html).toContain("max-h-[calc(100vh-6rem)]");
    expect(html).toContain("<main");
    expect(html).toContain("Dashboard content");
  });

  test("removes every Vault navigation entry when the release flag is off", async () => {
    const html = await renderShell(false);

    expect(html).not.toContain('href="/dashboard/vault"');
    expect(html).not.toContain('href="/dashboard/vault/sessions"');
    expect(html).toContain('href="/dashboard/coderouter"');
  });

  test("renders remote control devices and TestFlight together below coderouter", async () => {
    const html = await renderShell(true);

    expect(html).toContain('href="/dashboard/testflight"');
    const coderouterIndex = html.indexOf('href="/dashboard/coderouter"');
    const mobileDevicesIndex = html.indexOf('href="/dashboard/mobile-devices"');
    const testflightIndex = html.indexOf('href="/dashboard/testflight"');
    const billingIndex = html.indexOf('href="/dashboard/billing"');
    expect(coderouterIndex).toBeGreaterThan(-1);
    expect(mobileDevicesIndex).toBeGreaterThan(coderouterIndex);
    expect(testflightIndex).toBeGreaterThan(mobileDevicesIndex);
    expect(billingIndex).toBeGreaterThan(testflightIndex);
    expect(html.indexOf('href="/dashboard/settings"')).toBeGreaterThan(testflightIndex);
  });

  test("marks the current section, including nested vault session pages", async () => {
    pathname = "/dashboard/vault/sessions/abc";
    try {
      const html = await renderShell(true);
      const current = html.match(/<a[^>]*aria-current="page"[^>]*>/g) ?? [];
      // Desktop and mobile navigation each mark the same entry.
      expect(current).toHaveLength(2);
      expect(current.every((link) => link.includes('href="/dashboard/vault/sessions"'))).toBe(true);
    } finally {
      pathname = "/dashboard/testflight";
    }
  });

  test.each(locales)("names every navigation entry in %s without internal product names", async (locale) => {
    const html = await renderShell(false, locale);
    expect(html).toContain('href="/dashboard/mobile-devices"');
    const nav = (await loadMessages(locale)).dashboard as Record<string, Record<string, string>>;
    expect(html).toContain(nav.nav!.mobileDevices!);
    expect(html).not.toMatch(/iroh|Stack|Cloudflare|Durable Object/i);
  });
});
