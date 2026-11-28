import { expect, test } from "@playwright/test";

test("a 401 from any dashboard API sends the visitor to sign-in", async ({ page }) => {
  await page.goto("/dashboard");
  await expect(page.getByTestId("dashboard-shell")).toBeVisible();
  // The session ends after the shell loaded: the next API call is refused.
  await page.route("**/api/dashboard/rpc/account/billing", (route) =>
    route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"unauthorized"}' }));
  await page.locator("aside").first().getByRole("link", { name: "Settings", exact: true }).click();
  await page.getByTestId("settings-hub").getByRole("link", { name: "Plan & billing", exact: true }).first().click();
  await expect(page).toHaveURL(/\/handler\/sign-in/);
  expect(decodeURIComponent(decodeURIComponent(page.url()))).toContain("/dashboard/billing");
});
