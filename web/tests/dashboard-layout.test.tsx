import { expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

const pendingProvider = new Promise<never>(() => {});
let stackProviderPending = true;
let dashboardChildren: React.ReactNode;

mock.module("@stackframe/stack", () => ({
  StackProvider: ({ children }: React.PropsWithChildren) => {
    if (stackProviderPending) {
      void children;
      throw pendingProvider;
    }
    return children;
  },
  StackTheme: ({ children }: React.PropsWithChildren) => children,
}));

mock.module("@/app/lib/stack", () => ({
  getStackServerApp: () => ({}),
  isStackConfigured: () => true,
}));

mock.module(
  "../app/[locale]/dashboard/components/dashboard-skeleton",
  () => ({
    DashboardSkeleton: () => (
      <p data-testid="dashboard-suspense-fallback">Loading dashboard</p>
    ),
  }),
);

mock.module(
  "../app/[locale]/dashboard/components/query-provider",
  () => ({
    DashboardQueryProvider: ({ children }: React.PropsWithChildren) => children,
  }),
);

mock.module("../app/[locale]/dashboard/dashboard-shell", () => ({
  DashboardShell: ({ children }: React.PropsWithChildren) => {
    dashboardChildren = children;
    return children;
  },
}));

const { default: DashboardLayout } = await import(
  "../app/[locale]/dashboard/layout"
);

test("keeps Stack provider suspension inside the dashboard fallback", async () => {
  stackProviderPending = true;
  const html = renderToStaticMarkup(
    await DashboardLayout({
      children: <main>Dashboard content</main>,
      params: Promise.resolve({ locale: "en" }),
    }),
  );

  expect(html).toContain('data-testid="dashboard-suspense-fallback"');
  expect(html).not.toContain("Dashboard content");
});

test("passes page content directly to the shared dashboard shell", async () => {
  stackProviderPending = false;
  const content = <main>Dashboard content</main>;

  try {
    const html = renderToStaticMarkup(
      await DashboardLayout({
        children: content,
        params: Promise.resolve({ locale: "en" }),
      }),
    );

    expect(dashboardChildren).toBe(content);
    expect(html).toContain("Dashboard content");
  } finally {
    stackProviderPending = true;
    dashboardChildren = undefined;
  }
});
