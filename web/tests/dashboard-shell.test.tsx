import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

mock.module("../app/[locale]/dashboard/dashboard-account-menu", () => ({
  DashboardAccountMenu: () => <span data-testid="account-control" />,
}));

mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) =>
    children,
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("@/app/[locale]/theme", () => ({
  ThemeToggle: () => <span data-testid="theme-control" />,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) => (
    <a href={href} {...props}>{children}</a>
  ),
  usePathname: () => "/dashboard/testflight",
}));

const { DashboardShell } = await import(
  "../app/[locale]/dashboard/dashboard-shell"
);

describe("dashboard shell", () => {
  test("mounts one account control and one theme control across responsive layouts", () => {
    const html = renderToStaticMarkup(
      <DashboardShell vaultEnabled>
        <p>Dashboard content</p>
      </DashboardShell>,
    );

    expect(html.match(/data-testid="account-control"/g)).toHaveLength(1);
    expect(html.match(/data-testid="theme-control"/g)).toHaveLength(1);
    expect(html).toContain('href="/dashboard/coderouter"');
    const billingIndex = html.indexOf('href="/dashboard/billing"');
    const teamIndex = html.indexOf('href="/dashboard/team"');
    expect(billingIndex).toBeGreaterThan(-1);
    expect(teamIndex).toBeGreaterThan(billingIndex);
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
  });

  test("removes every Vault navigation entry when the release flag is off", () => {
    const html = renderToStaticMarkup(
      <DashboardShell vaultEnabled={false}>
        <p>Dashboard content</p>
      </DashboardShell>,
    );

    expect(html).not.toContain('href="/dashboard/vault"');
    expect(html).not.toContain('href="/dashboard/vault/sessions"');
    expect(html).not.toContain("vaultGroup");
    expect(html).toContain('href="/dashboard/coderouter"');
  });

  test("renders iOS TestFlight in its own section below coderouter", () => {
    const html = renderToStaticMarkup(
      <DashboardShell vaultEnabled>
        <p>Dashboard content</p>
      </DashboardShell>,
    );

    expect(html).toContain('href="/dashboard/testflight"');
    expect(html).toContain("iosGroup");
    // iOS section sits on its own, below coderouter and above the account group.
    const coderouterIndex = html.indexOf('href="/dashboard/coderouter"');
    const testflightIndex = html.indexOf('href="/dashboard/testflight"');
    const billingIndex = html.indexOf('href="/dashboard/billing"');
    expect(coderouterIndex).toBeGreaterThan(-1);
    expect(testflightIndex).toBeGreaterThan(coderouterIndex);
    expect(billingIndex).toBeGreaterThan(testflightIndex);
  });
});
