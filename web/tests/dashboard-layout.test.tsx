import { expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

let dashboardChildren: React.ReactNode;

mock.module("@stackframe/stack", () => ({
  StackProvider: ({ children }: React.PropsWithChildren) => children,
  StackTheme: ({ children }: React.PropsWithChildren) => children,
}));

mock.module("@/app/lib/stack", () => ({
  getStackServerApp: () => ({}),
  isStackConfigured: () => true,
}));

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

test("passes page content directly to the shared dashboard shell", async () => {
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
    dashboardChildren = undefined;
  }
});
