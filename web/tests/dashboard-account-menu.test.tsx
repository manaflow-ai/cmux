import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

let currentUser: {
  displayName: string;
  primaryEmail: string;
  signOut: () => Promise<void>;
  selectedTeam: { id: string } | null;
  useTeams: () => Array<{ id: string; displayName: string }>;
  setSelectedTeam: (team: unknown) => Promise<void>;
} | null = null;

mock.module("@stackframe/stack", () => ({
  AccountSettings: () => <section data-testid="stack-account-settings" />,
  useUser: () => currentUser,
  UserAvatar: ({ size }: { size: number }) => (
    <span data-testid="avatar" data-size={size} />
  ),
  TeamSwitcher: ({
    teams,
    teamId,
  }: {
    teams: Array<{ id: string }>;
    teamId?: string;
  }) => (
    <span
      data-testid="team-switcher"
      data-team-id={teamId}
      data-team-ids={teams.map((team) => team.id).join(",")}
    />
  ),
}));

mock.module("@tanstack/react-query", () => ({
  useQuery: () => ({
    data: {
      selectedTeamId: "team-2",
      teams: [
        {
          id: "team-2",
          name: "Authorized",
          personal: false,
          permissions: { use: true, manageAccounts: false },
        },
      ],
    },
  }),
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    throw new Error(`redirect:${target}`);
  },
  useRouter: () => ({
    push: () => undefined,
    refresh: () => undefined,
  }),
}));

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
      ...props
    }: React.HTMLAttributes<HTMLElement> & { render?: React.ReactElement }) =>
      render
        ? <span {...props}>{render}{children}</span>
        : <button {...props}>{children}</button>,
    Separator: () => <hr />,
  },
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) => (
    <a href={href} {...props}>{children}</a>
  ),
}));

const { DashboardAccountMenu } = await import(
  "../app/[locale]/dashboard/dashboard-account-menu"
);

describe("dashboard account menu", () => {
  test("matches the chatmux identity row and exposes working account actions", () => {
    currentUser = {
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
      selectedTeam: { id: "team-1" },
      useTeams: () => [
        { id: "team-1", displayName: "Not authorized" },
        { id: "team-2", displayName: "Authorized" },
      ],
      setSelectedTeam: async () => undefined,
    };
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain("Lawrence");
    expect(html).toContain("lawrence@example.com");
    expect(html).toContain('data-size="24"');
    expect(html).toContain('href="/dashboard/team"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain('data-testid="team-switcher"');
    expect(html).toContain('data-team-id="team-2"');
    expect(html).toContain('data-team-ids="team-2"');
    expect(html).not.toContain("Not authorized");
    expect(html).toContain("signOut");
  });

  test("uses the unlocalized auth handler and names the compact sign-in link", () => {
    currentUser = null;
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain('aria-label="signIn"');
    expect(html).toContain('href="/handler/sign-in?');
    expect(html).toContain("dashboard");
    expect(html).not.toContain("/en/handler/sign-in");
  });
});
