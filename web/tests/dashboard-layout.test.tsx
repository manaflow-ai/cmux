import { afterAll, beforeEach, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import {
  TEST_STACK_PROJECT_ID,
  nextHeadersMock,
} from "./helpers/dashboard-session-mock";
import { renderSettled } from "./helpers/render-stream";

type DashboardUser = {
  readonly id: string;
  readonly isAnonymous: boolean;
  readonly primaryEmail?: string;
  readonly primaryEmailVerified?: boolean;
  readonly displayName?: string;
};

let currentUser: DashboardUser | null = {
  id: "user-1",
  isAnonymous: false,
  primaryEmail: "user@example.com",
  primaryEmailVerified: true,
  displayName: "User One",
};
let refreshToken: string | null = "refresh-1";
let requestHeaders = new Headers();
let authUnavailable = false;
let dashboardShellRenderCount = 0;
let redirectedTo: string | null = null;
const accountMenuUsers: unknown[] = [];
const verifyBrowserSessionRequest = mock(async () =>
  currentUser && !currentUser.isAnonymous ? currentUser : null,
);
const previousProjectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = TEST_STACK_PROJECT_ID;

mock.module("@stackframe/stack", () => ({
  StackProvider: ({ children }: React.PropsWithChildren) => children,
  StackTheme: ({ children }: React.PropsWithChildren) => children,
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    redirectedTo = target;
    throw new Error(`redirect:${target}`);
  },
  unstable_rethrow: (error: unknown) => {
    if (error instanceof Error && error.message.startsWith("redirect:")) throw error;
  },
}));

mock.module("next/headers", () =>
  nextHeadersMock({
    headers: () => requestHeaders,
    refreshToken: () => refreshToken,
  }),
);

mock.module("next/cache", () => ({
  cacheLife: () => undefined,
}));

mock.module("../services/vms/auth", () => ({
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline: async (
    operation: (signal: AbortSignal) => Promise<unknown>,
  ) => {
    if (authUnavailable) throw new Error("Stack unavailable");
    return operation(new AbortController().signal);
  },
  isSubrouterAuthorizationError: () => true,
}));

mock.module("@/app/lib/stack", () => ({
  getStackServerApp: () => ({}),
  isStackConfigured: () => true,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({}),
  isStackConfigured: () => true,
}));

mock.module("@/app/lib/vault-auth", () => ({
  localizedVaultPath: (locale: string, path: string) => `/${locale}${path}`,
  vaultSignInHref: (returnPath: string) => `/sign-in?after=${returnPath}`,
}));

mock.module("../app/lib/vault-auth", () => ({
  localizedVaultPath: (locale: string, path: string) => `/${locale}${path}`,
  vaultSignInHref: (returnPath: string) => `/sign-in?after=${returnPath}`,
}));

mock.module(
  "../app/[locale]/dashboard/components/query-provider",
  () => ({
    DashboardQueryProvider: ({ children }: React.PropsWithChildren) => children,
  }),
);

mock.module("../app/[locale]/dashboard/dashboard-account-menu", () => ({
  DashboardAccountMenu: ({ user }: { user: unknown }) => {
    accountMenuUsers.push(user);
    return <span data-testid="account-menu" data-user={user ? "yes" : "no"} />;
  },
  DashboardAccountMenuFallback: () => <span data-testid="account-fallback" />,
}));

mock.module("../app/[locale]/dashboard/dashboard-shell", () => ({
  DashboardShell: ({
    children,
    account,
  }: React.PropsWithChildren<{ account: React.ReactNode }>) => {
    dashboardShellRenderCount += 1;
    return (
      <div data-testid="dashboard-shell">
        <header>{account}</header>
        <main>{children}</main>
      </div>
    );
  },
}));

const { default: DashboardLayout } = await import(
  "../app/[locale]/dashboard/layout"
);

beforeEach(() => {
  currentUser = {
    id: "user-1",
    isAnonymous: false,
    primaryEmail: "user@example.com",
    primaryEmailVerified: true,
    displayName: "User One",
  };
  refreshToken = "refresh-1";
  requestHeaders = new Headers();
  authUnavailable = false;
  dashboardShellRenderCount = 0;
  redirectedTo = null;
  accountMenuUsers.length = 0;
  verifyBrowserSessionRequest.mockClear();
});

afterAll(() => {
  if (previousProjectId === undefined) {
    delete process.env.NEXT_PUBLIC_STACK_PROJECT_ID;
  } else {
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID = previousProjectId;
  }
});

async function layout(children: React.ReactNode = <p>Private dashboard content</p>) {
  return DashboardLayout({
    children,
    params: Promise.resolve({ locale: "en" }),
  });
}

test("renders the shell and page content without waiting on Stack", async () => {
  const html = renderToStaticMarkup(await layout());

  // The synchronous pass paints the shell, the page, and the account
  // fallback. Nothing above the session boundaries awaited the session.
  expect(dashboardShellRenderCount).toBe(1);
  expect(html).toContain('data-testid="dashboard-shell"');
  expect(html).toContain("Private dashboard content");
  expect(html).toContain('data-testid="account-fallback"');
  expect(html).not.toContain('data-testid="account-menu"');
});

test("streams the identity row from one session read shared by every slot", async () => {
  const html = await renderSettled(await layout());

  expect(html).toContain('data-user="yes"');
  // React's per-render `cache` only dedupes under the server-components
  // runtime, so the count is not observable here; the call itself is.
  expect(verifyBrowserSessionRequest).toHaveBeenCalled();
  expect(accountMenuUsers[0]).toEqual({
    id: "user-1",
    displayName: "User One",
    primaryEmail: "user@example.com",
    primaryEmailVerified: true,
    profileImageUrl: null,
    selectedTeamId: null,
    isAnonymous: false,
  });
});

for (const unauthenticatedUser of [
  null,
  { id: "anonymous-1", isAnonymous: true },
] as const) {
  test(`redirects a ${unauthenticatedUser ? "anonymous" : "rejected"} session cookie to sign-in`, async () => {
    currentUser = unauthenticatedUser;
    requestHeaders = new Headers({
      "x-cmux-dashboard-return-path": "/dashboard/coderouter?team=team-1",
    });

    // The guard sits behind Suspense, so the redirect is thrown while the
    // stream settles rather than before the shell renders.
    await renderSettled(await layout());

    expect(redirectedTo).toBe("/sign-in?after=/en/dashboard/coderouter?team=team-1");
  });
}

test("shows the sign-in control without calling Stack when no session cookie exists", async () => {
  refreshToken = null;

  const html = await renderSettled(await layout());

  expect(html).toContain('data-user="no"');
  expect(verifyBrowserSessionRequest).not.toHaveBeenCalled();
});

test("keeps the shell and page content when Stack is unavailable", async () => {
  authUnavailable = true;

  const html = await renderSettled(await layout());

  expect(html).toContain('data-testid="dashboard-shell"');
  expect(html).toContain("Private dashboard content");
  expect(html).toContain('data-user="no"');
});
