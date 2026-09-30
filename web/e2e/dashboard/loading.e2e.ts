import { readFileSync } from "node:fs";
import path from "node:path";
import { expect, type Page, test } from "@playwright/test";
import { expectNoErrorCard, watchPage } from "./watch";

/** Dashboard procedure calls the SPA makes from the browser, e.g. `account/billing`. */
function recordRpc(page: Page): string[] {
  const calls: string[] = [];
  page.on("request", (request) => {
    const { pathname } = new URL(request.url());
    if (pathname.startsWith("/api/dashboard/rpc/")) calls.push(pathname.slice("/api/dashboard/rpc/".length));
  });
  return calls;
}

test("a full load renders server-prefetched data without fetching it again", async ({ page }) => {
  const watch = watchPage(page);
  const calls = recordRpc(page);
  await page.goto("/dashboard/billing");
  await expect(page.locator("main").getByRole("heading", { name: /billing/i }).first()).toBeVisible();
  await expectNoErrorCard(page);
  await expect(page.getByTestId("dashboard-section-skeleton")).toHaveCount(0);
  expect(calls).not.toContain("account/session");
  expect(calls).not.toContain("account/billing");
  watch.expectClean();
});

test("settings pages load their reads with the page, and hover preloads the next one", async ({ page }) => {
  const watch = watchPage(page);
  const calls = recordRpc(page);
  await page.goto("/dashboard/settings/notifications");
  await expect(page.locator("main").getByRole("heading").first()).toBeVisible();
  await expectNoErrorCard(page);
  expect(calls).not.toContain("settings/notifications");

  const sessionsLink = page.locator('a[href$="/dashboard/settings/sessions"]').first();
  await sessionsLink.hover();
  await expect.poll(() => calls.includes("settings/sessions")).toBe(true);
  await sessionsLink.click();
  await expect(page).toHaveURL(/\/dashboard\/settings\/sessions$/);
  await expect(page.getByText(/current/i).first()).toBeVisible();
  await expectNoErrorCard(page);
  expect(calls.filter((call) => call === "settings/sessions")).toHaveLength(1);

  await page.locator('a[href$="/dashboard/settings/api-keys"]').first().click();
  await expect(page).toHaveURL(/\/dashboard\/settings\/api-keys$/);
  await expectNoErrorCard(page);
  watch.expectClean();
});

test("a signed-out full load is redirected to sign-in by the server", async ({ browser, baseURL }) => {
  // Keep non-session cookies (a preview's deployment-protection bypass), drop the Hexclave session.
  const stored = JSON.parse(readFileSync(path.resolve("e2e/dashboard/.auth/state.json"), "utf8")) as {
    cookies: Parameters<Awaited<ReturnType<typeof browser.newContext>>["addCookies"]>[0];
  };
  const context = await browser.newContext({ storageState: { cookies: [], origins: [] }, baseURL });
  await context.addCookies(stored.cookies.filter((cookie) => !cookie.name.startsWith("hexclave")));
  const page = await context.newPage();
  const calls = recordRpc(page);
  await page.goto("/dashboard/billing?billing=error");
  await expect(page).toHaveURL(/\/handler\/sign-in/);
  expect(calls).toEqual([]);
  await context.close();
});
