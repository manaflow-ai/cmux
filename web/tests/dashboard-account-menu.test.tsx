import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

type MenuUser = Parameters<typeof DashboardAccountMenu>[0]["user"];
let currentUser: MenuUser = null;
const appSignOut = mock(async () => undefined);

mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ signOut: appSignOut }),
  UserAvatar: ({ size }: { size: number }) => (
    <span data-testid="avatar" data-size={size} />
  ),
}));

let radioGroupValue = "";
mock.module("@base-ui-components/react/menu", () => ({
  Menu: {
    Root: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Trigger: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
      <button {...props}>{children}</button>
    ),
    Portal: ({ children }: { children: React.ReactNode }) => <>{children}</>,
    Positioner: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Popup: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
    Item: ({
      children,
      render,
      ...itemProps
    }: React.HTMLAttributes<HTMLElement> & { render?: React.ReactElement; closeOnClick?: boolean }) => {
      const { closeOnClick, ...props } = itemProps;
      void closeOnClick;
      return render
        ? <span {...props}>{render}{children}</span>
        : <button {...props}>{children}</button>;
    },
    Separator: () => <hr />,
    SubmenuRoot: ({ children }: { children: React.ReactNode }) => <div data-testid="team-submenu">{children}</div>,
    RadioGroup: ({ children, value }: { children: React.ReactNode; value: string }) => {
      radioGroupValue = value;
      return <div role="group">{children}</div>;
    },
    RadioItem: ({ children, value, ...props }: React.HTMLAttributes<HTMLElement> & { value: string }) => (
      <div role="menuitemradio" aria-checked={value === radioGroupValue} {...props}>{children}</div>
    ),
    RadioItemIndicator: ({ children }: { children: React.ReactNode }) => <span>{children}</span>,
    SubmenuTrigger: ({ children, ...props }: React.HTMLAttributes<HTMLElement>) => (
      <button {...props}>{children}</button>
    ),
  },
}));

let resolvedTheme = "dark";
const themeToggle = mock(() => undefined);
mock.module("@/app/[locale]/theme", () => ({
  useThemeToggle: () => ({ resolvedTheme, toggle: themeToggle }),
}));

let teamScope: unknown = { status: "unavailable" };
mock.module("../dashboard-app/shell/dashboard-team-scope", () => ({
  useDashboardTeamScope: () => teamScope,
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("@tanstack/react-router", () => ({
  Link: ({
    to,
    children,
    ...props
  }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) => (
    <a href={to} {...props}>{children}</a>
  ),
}));

const { DashboardAccountMenu } = await import(
  "../dashboard-app/shell/dashboard-account-menu"
);
const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
const { planQuery } = await import("../dashboard-app/queries/billing");

type Plan = { planId: "free" | "go" | "pro" | "max"; isPro: boolean; billingManagement: "stripe" | "external" | "none" };

/** The menu with the viewer's plan in the cache (or none, as while it loads). */
function renderMenu(user: MenuUser, plan?: Plan) {
  const queryClient = new QueryClient();
  if (plan) queryClient.setQueryData(planQuery.queryKey, plan);
  return renderToStaticMarkup(
    <QueryClientProvider client={queryClient}>
      <DashboardAccountMenu user={user} />
    </QueryClientProvider>,
  );
}

function sessionUser(): MenuUser {
  return {
    id: "user-lawrence",
    displayName: "Lawrence",
    primaryEmail: "lawrence@example.com",
    primaryEmailVerified: true,
    profileImageUrl: null,
    selectedTeamId: null,
  };
}

describe("dashboard account menu", () => {
  test("matches the chatmux identity row and exposes the account menu", () => {
    currentUser = sessionUser();
    const html = renderMenu(currentUser);

    expect(html).toContain("Lawrence");
    expect(html).toContain("lawrence@example.com");
    expect(html).toContain('data-size="24"');
    expect(html).toContain('href="/dashboard/settings"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain("signOut");
    // Switch account opens the sign-in page's chooser, back to the dashboard.
    expect(html).toContain(">switchAccount<");
    expect(html).toMatch(/href="\/handler\/sign-in\?[^"]*prompt=select_account/);
    // Without a team catalog the menu has no team entry at all.
    expect(html).not.toContain("team-submenu");
  });

  test("offers the theme switch inside the menu, named after the theme it switches to", () => {
    currentUser = sessionUser();
    resolvedTheme = "dark";
    expect(renderMenu(currentUser)).toContain(">themeLight<");
    resolvedTheme = "light";
    const html = renderMenu(currentUser);
    expect(html).toContain(">themeDark<");
    expect(html.indexOf(">themeDark<")).toBeGreaterThan(html.indexOf("/dashboard/settings"));
    expect(html.indexOf(">themeDark<")).toBeLessThan(html.indexOf("/dashboard/billing"));
  });

  test("lists every permitted team in a submenu and shows the current one on the trigger", () => {
    currentUser = sessionUser();
    const teams = [
      { id: "user-lawrence", name: "Lawrence", personal: true, permissions: { use: true, manageAccounts: true } },
      { id: "team-2", name: "Manaflow", personal: false, permissions: { use: true, manageAccounts: true } },
      { id: "team-3", name: "Side project", personal: false, permissions: { use: true, manageAccounts: false } },
    ];
    teamScope = {
      status: "ready",
      teams,
      selected: teams[1],
      switchTeam: () => undefined,
      refreshError: false,
      retryRefresh: () => undefined,
    };
    resolvedTheme = "dark";
    const html = renderMenu(currentUser);
    teamScope = { status: "unavailable" };

    expect(html.match(/data-testid="team-submenu"/g)).toHaveLength(1);
    const submenu = html.slice(html.indexOf('data-testid="team-submenu"'));
    expect(submenu).toContain("Manaflow");
    expect(submenu).toContain("Side project");
    expect(submenu).toContain(">Lawrence<");
    expect(submenu.match(/aria-checked="true"/g)).toHaveLength(1);
    expect(submenu.match(/aria-checked="false"/g)).toHaveLength(2);
    // The trigger row names the current team under the user's name.
    expect(html.indexOf("Manaflow")).toBeLessThan(html.indexOf("/dashboard/settings"));
    // Order: settings, theme, billing, team, switch account, then sign out.
    const order = ["/dashboard/settings", ">themeLight<", "/dashboard/billing", 'data-testid="team-submenu"', ">switchAccount<", ">signOut<"]
      .map((marker) => html.indexOf(marker));
    expect(order.every((index) => index >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  test("uses the unlocalized auth handler and names the compact sign-in link", () => {
    currentUser = null;
    const html = renderMenu(currentUser);

    expect(html).toContain('aria-label="signIn"');
    expect(html).toContain('href="/handler/sign-in?');
    expect(html).toContain("dashboard");
    expect(html).not.toContain("/en/handler/sign-in");
  });

  test("shows a retry action when the dashboard refresh fails after switching", () => {
    currentUser = sessionUser();
    const teams = [
      { id: "user-lawrence", name: "Lawrence", personal: true, permissions: { use: true, manageAccounts: true } },
      { id: "team-2", name: "Manaflow", personal: false, permissions: { use: true, manageAccounts: true } },
    ];
    teamScope = {
      status: "ready",
      teams,
      selected: teams[1],
      switchTeam: () => undefined,
      refreshError: true,
      retryRefresh: () => undefined,
    };

    const html = renderMenu(currentUser);
    expect(html).toContain('role="alert"');
    expect(html).toContain('>retry<');
    teamScope = { status: "unavailable" };
  });

  test("shows the plan under the name, and Upgrade only for a Free account", () => {
    currentUser = sessionUser();
    const free = renderMenu(currentUser, { planId: "free", isPro: false, billingManagement: "none" });
    expect(free).toContain('data-testid="account-plan"');
    expect(free).toContain(">names.free<");
    expect(free).toContain(">upgrade<");
    const pro = renderMenu(currentUser, { planId: "max", isPro: true, billingManagement: "stripe" });
    expect(pro).toContain(">names.max<");
    expect(pro).not.toContain(">upgrade<");
    // While the plan loads there is neither a badge nor an upgrade prompt.
    const loading = renderMenu(currentUser);
    expect(loading).not.toContain('data-testid="account-plan"');
    expect(loading).not.toContain(">upgrade<");
  });
});
