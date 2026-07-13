import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

const { default: AppProWelcomePage } = await import("../app/app-pro-welcome/page");

describe("app pro welcome page", () => {
  test("redirects to the dashboard billing page outside the cmux app", async () => {
    await expect(
      AppProWelcomePage({ searchParams: Promise.resolve({}) }),
    ).rejects.toMatchObject({
      digest: expect.stringContaining(";/dashboard/billing;"),
    });
  });

  test("renders the welcome checklist with dashboard links inside the cmux app", async () => {
    const element = await AppProWelcomePage({
      searchParams: Promise.resolve({ cmux_app: "1", appearance: "dark" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain("Welcome to cmux Pro");
    expect(html).toContain("Model gateway");
    expect(html).toContain("cmux iOS app");
    expect(html).toContain('href="/dashboard/subrouter"');
    expect(html).toContain('href="/dashboard/ai-accounts"');
    expect(html).toContain('href="/dashboard/testflight"');
    expect(html).toContain('href="/dashboard/billing"');
    expect(html).toContain('data-app-pro-welcome-appearance="dark"');
  });
});
