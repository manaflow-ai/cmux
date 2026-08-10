import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

let currentUser: {
  id: string;
  displayName: string;
  primaryEmail: string;
  signOut: () => Promise<void>;
  selectedTeam: { id: string } | null;
  useTeams: () => Array<{ id: string; displayName: string }>;
  setSelectedTeam: (team: unknown) => Promise<void>;
} | null = null;
let organizationQuery: {
  data?: {
    selectedTeamId: string | null;
    teams: Array<{
      id: string;
      name: string;
      personal: boolean;
      permissions: { use: boolean; manageAccounts: boolean };
    }>;
  };
  isPending: boolean;
  isError: boolean;
} = { data: undefined, isPending: true, isError: false };
const handlers: {
  switchOrganization?: (
    team: { id: string; displayName: string } | null,
  ) => Promise<void>;
} = {};
const routerPush = mock(() => undefined);
const routerReplace = mock(() => undefined);
const routerRefresh = mock(() => undefined);
const setQueryData = mock(() => undefined);
let organizationQueryKey: readonly unknown[] | undefined;

mock.module("@stackframe/stack", () => ({
  AccountSettings: () => <section data-testid="stack-account-settings" />,
  useUser: () => currentUser,
  UserAvatar: ({ size }: { size: number }) => (
    <span data-testid="avatar" data-size={size} />
  ),
  TeamSwitcher: ({
    teams,
    teamId,
    onChange,
    allowNull,
  }: {
    teams: Array<{ id: string }>;
    teamId?: string;
    onChange: (
      team: { id: string; displayName: string } | null,
    ) => Promise<void>;
    allowNull?: boolean;
  }) => {
    handlers.switchOrganization = onChange;
    return (
      <span
        data-testid="team-switcher"
        data-team-id={teamId}
        data-team-ids={teams.map((team) => team.id).join(",")}
        data-allow-null={allowNull}
      />
    );
  },
}));

mock.module("@tanstack/react-query", () => ({
  useQuery: (options: { queryKey: readonly unknown[] }) => {
    organizationQueryKey = options.queryKey;
    return organizationQuery;
  },
  useQueryClient: () => ({ setQueryData }),
}));

mock.module("next/navigation", () =>
  createNextNavigationMock((target: unknown) => {
    throw new Error(`redirect:${target}`);
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
  useRouter: () => ({
    push: routerPush,
    replace: routerReplace,
    refresh: routerRefresh,
  }),
}));

const { DashboardAccountMenu, __test } = await import(
  "../app/[locale]/dashboard/dashboard-account-menu"
);

describe("dashboard account menu", () => {
  test("matches the chatmux identity row and switches only authorized organizations", async () => {
    organizationQuery = {
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
      isPending: false,
      // A failed background refetch must not hide previously cached data.
      isError: true,
    };
    delete handlers.switchOrganization;
    routerPush.mockClear();
    routerRefresh.mockClear();
    setQueryData.mockClear();
    const setSelectedTeam = mock(async () => undefined);
    currentUser = {
      id: "user-lawrence",
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
      selectedTeam: { id: "team-1" },
      useTeams: () => [
        { id: "team-1", displayName: "Not authorized" },
        { id: "team-2", displayName: "Authorized" },
      ],
      setSelectedTeam,
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
    expect(organizationQueryKey).toEqual([
      "coderouter-organizations",
      "user-lawrence",
    ]);

    const invokeSwitch = handlers.switchOrganization as
      | ((
        team: { id: string; displayName: string } | null,
      ) => Promise<void>)
      | undefined;
    await invokeSwitch?.({
      id: "team-2",
      displayName: "Authorized",
    });
    expect(setSelectedTeam).toHaveBeenCalledWith({
      id: "team-2",
      displayName: "Authorized",
    });
    expect(routerPush).toHaveBeenCalledWith(
      "/dashboard/coderouter?team=team-2",
    );
    expect(routerRefresh).toHaveBeenCalledTimes(1);
    expect(setQueryData).toHaveBeenCalled();
  });

  test("uses the unlocalized auth handler and names the compact sign-in link", () => {
    currentUser = null;
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain('aria-label="signIn"');
    expect(html).toContain('href="/handler/sign-in?');
    expect(html).toContain("dashboard");
    expect(html).not.toContain("/en/handler/sign-in");
  });

  test("shows account settings instead of an endless loader after catalog failure", () => {
    organizationQuery = {
      data: undefined,
      isPending: false,
      isError: true,
    };
    currentUser = {
      id: "user-lawrence",
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
      selectedTeam: null,
      useTeams: () => [],
      setSelectedTeam: async () => undefined,
    };
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain('href="/dashboard/team"');
    expect(html).not.toContain("animate-pulse");
  });

  test("keeps a null Stack selection on the authorized personal organization", () => {
    organizationQuery = {
      data: {
        selectedTeamId: null,
        teams: [
          {
            id: "user-lawrence",
            name: "Personal",
            personal: true,
            permissions: { use: true, manageAccounts: true },
          },
          {
            id: "team-2",
            name: "Team",
            personal: false,
            permissions: { use: true, manageAccounts: true },
          },
        ],
      },
      isPending: false,
      isError: false,
    };
    currentUser = {
      id: "user-lawrence",
      displayName: "Lawrence",
      primaryEmail: "lawrence@example.com",
      signOut: async () => undefined,
      selectedTeam: null,
      useTeams: () => [{ id: "team-2", displayName: "Team" }],
      setSelectedTeam: async () => undefined,
    };
    const html = renderToStaticMarkup(<DashboardAccountMenu />);

    expect(html).toContain('data-allow-null="true"');
    expect(html).not.toContain('data-team-id="team-2"');
  });

  test("rejects malformed organization entries at the response boundary", () => {
    expect(__test.parseOrganizationCatalog({
      selectedTeamId: null,
      teams: [null],
    })).toBeNull();
    expect(__test.parseOrganizationCatalog({
      selectedTeamId: "missing",
      teams: [{ id: "team-1", name: "Team", personal: false }],
    })).toBeNull();
  });
});
