import { expect, test } from "@playwright/test";
import { expectNoErrorCard, watchPage } from "./watch";

const SIDEBAR: ReadonlyArray<{ link: string; path: string; heading: RegExp }> = [
  { link: "Mac access", path: "/dashboard/cloud", heading: /mac access/i },
  { link: "overview", path: "/dashboard/coderouter", heading: /coderouter/i },
  { link: "Mobile devices", path: "/dashboard/mobile-devices", heading: /mobile devices/i },
  { link: "iOS TestFlight", path: "/dashboard/testflight", heading: /testflight/i },
  { link: "settings", path: "/dashboard/settings", heading: /profile/i },
  { link: "teams", path: "/dashboard/teams", heading: /^teams$/i },
  { link: "billing", path: "/dashboard/billing", heading: /billing/i },
];

test("every sidebar section renders through client-side navigation", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard");
  await expect(page.getByTestId("dashboard-shell")).toBeVisible();
  // A full document load would reset this marker.
  await page.evaluate(() => { (window as unknown as { __spa: boolean }).__spa = true; });

  const sidebar = page.locator("aside");
  for (const item of SIDEBAR) {
    await sidebar.getByRole("link", { name: item.link, exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`${item.path}(\\?.*)?$`));
    await expect(page.locator("main").getByRole("heading", { name: item.heading }).first()).toBeVisible();
    await expectNoErrorCard(page);
  }
  expect(await page.evaluate(() => (window as unknown as { __spa?: boolean }).__spa)).toBe(true);

  await page.goBack();
  await expect(page).toHaveURL(/\/dashboard\/teams$/);
  await expect(page.locator("main").getByRole("heading", { name: /^teams$/i })).toBeVisible();
  await page.goForward();
  await expect(page).toHaveURL(/\/dashboard\/billing$/);
  await expect(page.locator("main").getByRole("heading", { name: /billing/i }).first()).toBeVisible();
  watch.expectClean();
});

test("deep links load directly and keep their search params", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard/settings/notifications");
  await expect(page.locator("main").getByRole("heading", { name: /notifications/i }).first()).toBeVisible();
  await page.goto("/dashboard/billing?billing=cancelled");
  await expect(page).toHaveURL(/billing=cancelled/);
  await expect(page.locator("main").getByRole("heading", { name: /billing/i }).first()).toBeVisible();
  watch.expectClean();
});

test("legacy dashboard URLs redirect inside the SPA", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard/ai-accounts");
  await expect(page).toHaveURL(/\/dashboard\/coderouter/);
  await page.goto("/dashboard/team#team-creation");
  await expect(page).toHaveURL(/\/dashboard\/teams\/new/);
  watch.expectClean();
});

test("a localized dashboard keeps its locale prefix", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/ja/dashboard/teams");
  await expect(page.getByTestId("dashboard-shell")).toBeVisible();
  await page.locator("aside").getByRole("link").filter({ hasText: /./ }).nth(6).click();
  await expect(page).toHaveURL(/\/ja\/dashboard\//);
  watch.expectClean();
});

test("unknown dashboard paths render not-found inside the frame", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard/does-not-exist");
  await expect(page.getByTestId("dashboard-shell")).toBeVisible();
  await expect(page.getByText("Page not found")).toBeVisible();
  watch.expectClean();
});

test("the SPA keeps working after leaving to a Next page and coming back", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard/teams");
  await expect(page.locator("main").getByRole("heading", { name: /^teams$/i })).toBeVisible();
  await page.goto("/pricing");
  await page.goBack();
  await expect(page).toHaveURL(/\/dashboard\/teams$/);
  await expect(page.locator("main").getByRole("heading", { name: /^teams$/i })).toBeVisible();
  await page.locator("aside").getByRole("link", { name: "billing", exact: true }).click();
  await page.goBack();
  await expect(page.locator("main").getByRole("heading", { name: /^teams$/i })).toBeVisible();
  watch.expectClean();
});
