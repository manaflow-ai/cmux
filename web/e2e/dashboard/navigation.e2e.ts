import { expect, test } from "@playwright/test";
import { expectNoErrorCard, watchPage } from "./watch";

const SIDEBAR: ReadonlyArray<{ link: string; path: string; heading: RegExp }> = [
  { link: "Mac access", path: "/dashboard/cloud", heading: /mac access/i },
  { link: "Overview", path: "/dashboard/coderouter", heading: /coderouter/i },
  { link: "Mobile devices", path: "/dashboard/mobile-devices", heading: /mobile devices/i },
  { link: "iOS TestFlight", path: "/dashboard/testflight", heading: /testflight/i },
  { link: "Settings", path: "/dashboard/settings", heading: /profile/i },
];

/** Settings is the hub: billing and teams open from its subnav. */
const HUB: ReadonlyArray<{ link: string; path: string; heading: RegExp }> = [
  { link: "Plan & billing", path: "/dashboard/billing", heading: /plan & billing/i },
  { link: "Create team", path: "/dashboard/teams/new", heading: /create a team/i },
];

test("every sidebar section and hub page renders through client-side navigation", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard");
  await expect(page.getByTestId("dashboard-shell")).toBeVisible();
  // A full document load would reset this marker.
  await page.evaluate(() => { (window as unknown as { __spa: boolean }).__spa = true; });

  const sidebar = page.locator("aside").first();
  for (const item of SIDEBAR) {
    await sidebar.getByRole("link", { name: item.link, exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`${item.path}(\\?.*)?$`));
    await expect(page.locator("main").getByRole("heading", { name: item.heading }).first()).toBeVisible();
    await expectNoErrorCard(page);
  }
  const hub = page.getByTestId("settings-hub");
  for (const item of HUB) {
    await hub.getByRole("link", { name: item.link, exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(`${item.path}(\\?.*)?$`));
    await expect(page.locator("main").getByRole("heading", { name: item.heading }).first()).toBeVisible();
    // The sidebar keeps Settings current on every hub page.
    await expect(sidebar.getByRole("link", { name: "Settings", exact: true })).toHaveAttribute("aria-current", "page");
    await expectNoErrorCard(page);
  }
  expect(await page.evaluate(() => (window as unknown as { __spa?: boolean }).__spa)).toBe(true);

  await page.goBack();
  await expect(page).toHaveURL(/\/dashboard\/billing$/);
  await expect(page.locator("main").getByRole("heading", { name: /plan & billing/i }).first()).toBeVisible();
  await page.goForward();
  await expect(page).toHaveURL(/\/dashboard\/teams\/new$/);
  watch.expectClean();
});

test("deep links load directly and keep their search params", async ({ page }) => {
  const watch = watchPage(page);
  await page.goto("/dashboard/settings/notifications");
  await expect(page.locator("main").getByRole("heading", { name: /notifications/i }).first()).toBeVisible();
  await page.goto("/dashboard/billing?billing=cancelled");
  await expect(page).toHaveURL(/billing=cancelled/);
  await expect(page.locator("main").getByRole("heading", { name: /plan & billing/i }).first()).toBeVisible();
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
  // The first sidebar entry after the brand link.
  await page.locator("aside").first().getByRole("link").nth(1).click();
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
  await page.getByTestId("settings-hub").getByRole("link", { name: "Plan & billing", exact: true }).first().click();
  await page.goBack();
  await expect(page.locator("main").getByRole("heading", { name: /^teams$/i })).toBeVisible();
  watch.expectClean();
});
