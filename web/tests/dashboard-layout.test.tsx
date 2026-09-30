import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";

let stackConfigured = true;
let redirectedTo: string | null = null;

const realStack = await import("@hexclave/next");
mock.module("@hexclave/next", () => ({
  ...realStack,
  StackTheme: ({ children }: React.PropsWithChildren) => <div data-testid="stack-theme">{children}</div>,
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    redirectedTo = target;
    throw new Error(`redirect:${target}`);
  },
}));

// The dashboard prefetch reaches the team services, and their seat sync
// imports the purchase service: carry every real export the chain needs.
const realAppStack = await import("@/app/lib/stack");
mock.module("@/app/lib/stack", () => ({
  ...realAppStack,
  isStackConfigured: () => stackConfigured,
  getStackServerApp: () => ({}),
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

const layoutModule = await import("../app/[locale]/dashboard/layout");
const pageModule = await import("../app/[locale]/dashboard/[[...path]]/page");
const DashboardLayout = layoutModule.default;
const DashboardPage = pageModule.default;

beforeEach(() => {
  stackConfigured = true;
  redirectedTo = null;
});

describe("dashboard Next shell", () => {
  test("the layout only adds the Stack theme around the SPA", () => {
    const html = renderToStaticMarkup(
      <DashboardLayout>
        <p>SPA</p>
      </DashboardLayout>,
    );
    expect(html).toBe('<div data-testid="stack-theme"><p>SPA</p></div>');
    expect(redirectedTo).toBeNull();
  });

  test("the layout sends visitors home when Stack is not configured", () => {
    stackConfigured = false;
    expect(() => DashboardLayout({ children: <p>SPA</p> })).toThrow("redirect:/");
    expect(redirectedTo).toBe("/");
  });

  test("every dashboard URL shares one static shell", () => {
    // No instant validation: the SPA owns navigation inside /dashboard.
    expect("instant" in layoutModule).toBe(false);
    expect("instant" in pageModule).toBe(false);
  });

  test("the static shell is the skeleton; the request-time prefetch streams in behind Suspense", () => {
    const pending = new Promise<never>(() => undefined);
    const html = renderToStaticMarkup(<DashboardPage params={pending} searchParams={pending} />);
    expect(html).toContain('aria-hidden="true"');
    expect(html).toContain('data-testid="dashboard-section-skeleton"');
    expect(html).not.toContain("dashboard-shell");
  });
});
