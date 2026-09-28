import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import { TEST_STACK_PROJECT_ID } from "./helpers/dashboard-session-mock";

const previousStackProjectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = TEST_STACK_PROJECT_ID;
afterAll(() => {
  if (previousStackProjectId === undefined) {
    delete process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
  } else {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = previousStackProjectId;
  }
});

let stackConfigured = true;
let redirectedTo: string | null = null;

mock.module("next/navigation", () =>
  createNextNavigationMock((target: unknown) => {
    redirectedTo = String(target);
    throw new Error(`redirect:${target}`);
  }),
);

mock.module("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({ href, children, ...props }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) => (
    <a href={href} {...props}>{children}</a>
  ),
  useRouter: () => ({ replace: () => undefined, refresh: () => undefined }),
  usePathname: () => "/dashboard/team",
}));

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => stackConfigured,
}));

const { default: DashboardTeamPage } = await import("../app/[locale]/dashboard/team/page");
const { settingsRouteForHash } = await import("../app/[locale]/dashboard/team/team-hash-redirect");

describe("legacy /dashboard/team route", () => {
  beforeEach(() => {
    stackConfigured = true;
    redirectedTo = null;
  });

  test("renders the client hash redirect instead of Hexclave account settings", async () => {
    const html = renderToStaticMarkup(
      await DashboardTeamPage({ params: Promise.resolve({ locale: "en" }) }),
    );
    expect(html).toContain('data-testid="team-hash-redirect"');
    expect(html).toContain('href="/dashboard/settings"');
    expect(redirectedTo).toBeNull();
  });

  test("preserves the active locale when Stack is unavailable", async () => {
    stackConfigured = false;
    await expect(
      DashboardTeamPage({ params: Promise.resolve({ locale: "ja" }) }),
    ).rejects.toThrow("redirect:/ja");
    expect(redirectedTo).toBe("/ja");
  });
});

describe("settingsRouteForHash", () => {
  test.each([
    ["#team-team_123", "/dashboard/teams/team_123"],
    ["#team-a%2Fb", "/dashboard/teams/a%2Fb"],
    ["#team-creation", "/dashboard/teams/new"],
    ["#profile", "/dashboard/settings"],
    ["#auth", "/dashboard/settings/auth"],
    ["#notifications", "/dashboard/settings/notifications"],
    ["#sessions", "/dashboard/settings/sessions"],
    ["#api-keys", "/dashboard/settings/api-keys"],
    ["#settings", "/dashboard/settings/account"],
    ["#payments", "/dashboard/billing"],
    ["", "/dashboard/settings"],
    ["#", "/dashboard/settings"],
    ["#team-", "/dashboard/settings"],
    ["#unknown", "/dashboard/settings"],
    ["#constructor", "/dashboard/settings"],
    ["#%E0%A4%A", "/dashboard/settings"],
  ])("maps %p to %p", (hash, route) => {
    expect(settingsRouteForHash(hash)).toBe(route);
  });
});
