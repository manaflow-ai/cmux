import { beforeEach, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

type DashboardUser = {
  readonly id: string;
  readonly isAnonymous: boolean;
};

let currentUser: DashboardUser | null = {
  id: "user-1",
  isAnonymous: false,
};
let requestHeaders = new Headers();
let authUnavailable = false;
let knownAuthError = true;
let dashboardShellRenderCount = 0;
const getUser = mock(async () => currentUser);
const verifyBrowserSessionRequest = mock(async () =>
  currentUser && !currentUser.isAnonymous ? currentUser : null,
);

mock.module("@stackframe/stack", () => ({
  StackProvider: ({ children }: React.PropsWithChildren) => children,
  StackTheme: ({ children }: React.PropsWithChildren) => children,
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    throw new Error(`redirect:${target}`);
  },
}));

mock.module("next/headers", () => ({
  headers: async () => requestHeaders,
}));

mock.module("next-intl/server", () => ({
  getTranslations: async () => (key: string) => ({
    genericTitle: "Sign-in could not be completed",
    genericBody: "Please try again.",
    backToSignIn: "Back to sign in",
  }[key] ?? key),
}));

mock.module("../services/vms/auth", () => ({
  verifyBrowserSessionRequest,
  withSubrouterAuthorizationDeadline: async (
    operation: (signal: AbortSignal) => Promise<unknown>,
  ) => {
    if (authUnavailable) throw new Error("Stack unavailable");
    return operation(new AbortController().signal);
  },
  isSubrouterAuthorizationError: () => knownAuthError,
}));

mock.module("@/app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
}));

mock.module("@/app/lib/vault-auth", () => ({
  localizedVaultPath: (locale: string, path: string) => `/${locale}${path}`,
  vaultSignInHref: (returnPath: string) => `/sign-in?after=${returnPath}`,
}));

mock.module(
  "../app/[locale]/dashboard/components/query-provider",
  () => ({
    DashboardQueryProvider: ({ children }: React.PropsWithChildren) => children,
  }),
);

mock.module("../app/[locale]/dashboard/dashboard-shell", () => ({
  DashboardShell: ({ children }: React.PropsWithChildren) => {
    dashboardShellRenderCount += 1;
    return children;
  },
}));

const { default: DashboardLayout } = await import(
  "../app/[locale]/dashboard/layout"
);

beforeEach(() => {
  currentUser = { id: "user-1", isAnonymous: false };
  requestHeaders = new Headers();
  authUnavailable = false;
  knownAuthError = true;
  dashboardShellRenderCount = 0;
  getUser.mockClear();
  verifyBrowserSessionRequest.mockClear();
});

for (const unauthenticatedUser of [
  null,
  { id: "anonymous-1", isAnonymous: true },
] as const) {
  test(`redirects ${unauthenticatedUser ? "anonymous" : "missing"} users before rendering the dashboard shell`, async () => {
    currentUser = unauthenticatedUser;

    await expect(
      DashboardLayout({
        children: <main>Private dashboard content</main>,
        params: Promise.resolve({ locale: "en" }),
      }),
    ).rejects.toThrow("redirect:/sign-in?after=/en/dashboard");

    expect(verifyBrowserSessionRequest).toHaveBeenCalledTimes(1);
    expect(dashboardShellRenderCount).toBe(0);
  });
}

test("renders the dashboard shell only after server authentication succeeds", async () => {
  const content = <main>Private dashboard content</main>;
  const html = renderToStaticMarkup(
    await DashboardLayout({
      children: content,
      params: Promise.resolve({ locale: "en" }),
    }),
  );

  expect(verifyBrowserSessionRequest).toHaveBeenCalledTimes(1);
  expect(dashboardShellRenderCount).toBe(1);
  expect(html).toContain("Private dashboard content");
});

test("preserves the deep dashboard destination through sign-in", async () => {
  currentUser = null;
  requestHeaders = new Headers({
    "x-cmux-dashboard-return-path": "/dashboard/coderouter?team=team-1",
  });

  await expect(
    DashboardLayout({
      children: <main>Private dashboard content</main>,
      params: Promise.resolve({ locale: "en" }),
    }),
  ).rejects.toThrow(
    "redirect:/sign-in?after=/en/dashboard/coderouter?team=team-1",
  );
  expect(dashboardShellRenderCount).toBe(0);
});

test("returns recovery UI without mounting the shell when auth times out", async () => {
  authUnavailable = true;

  const html = renderToStaticMarkup(
    await DashboardLayout({
      children: <main>Private dashboard content</main>,
      params: Promise.resolve({ locale: "en" }),
    }),
  );

  expect(html).toContain("Sign-in could not be completed");
  expect(html).toContain("Back to sign in");
  expect(html).not.toContain("Private dashboard content");
  expect(html).not.toContain('data-testid="dashboard-shell"');
  expect(dashboardShellRenderCount).toBe(0);
});

test("does not hide an unknown server failure as an auth outage", async () => {
  authUnavailable = true;
  knownAuthError = false;

  await expect(
    DashboardLayout({
      children: <main>Private dashboard content</main>,
      params: Promise.resolve({ locale: "en" }),
    }),
  ).rejects.toThrow("Stack unavailable");
  expect(dashboardShellRenderCount).toBe(0);
});
