import { expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

const pendingProvider = new Promise<never>(() => {});

mock.module("@stackframe/stack", () => ({
  StackProvider: ({ children }: React.PropsWithChildren) => {
    void children;
    throw pendingProvider;
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
  DashboardShell: ({ children }: React.PropsWithChildren) => children,
}));

const { default: DashboardLayout } = await import(
  "../app/[locale]/dashboard/layout"
);

test("keeps Stack provider suspension inside the dashboard fallback", async () => {
  const html = renderToStaticMarkup(
    await DashboardLayout({
      children: <main>Dashboard content</main>,
      params: Promise.resolve({ locale: "en" }),
    }),
  );

  expect(html).toContain('data-testid="dashboard-suspense-fallback"');
  expect(html).not.toContain("Dashboard content");
});
