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
let dashboardShellRenderCount = 0;
const getUser = mock(async () => currentUser);

mock.module("@stackframe/stack", () => ({
  StackProvider: ({ children }: React.PropsWithChildren) => children,
  StackTheme: ({ children }: React.PropsWithChildren) => children,
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    throw new Error(`redirect:${target}`);
  },
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
  dashboardShellRenderCount = 0;
  getUser.mockClear();
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

    expect(getUser).toHaveBeenCalledTimes(1);
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

  expect(getUser).toHaveBeenCalledTimes(1);
  expect(dashboardShellRenderCount).toBe(1);
  expect(html).toContain("Private dashboard content");
});
