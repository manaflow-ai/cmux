import { expect, test } from "@playwright/test";

test("redirects signed-out CLI authorization to sign-in with its login code", async ({ page }) => {
  const loginCode = "instant-e2e-login-code";

  await page.goto(`/handler/cli-auth-confirm?login_code=${loginCode}`);

  const currentURL = new URL(page.url());
  expect(currentURL.pathname).toBe("/handler/sign-in");
  expect(currentURL.searchParams.get("after_auth_return_to")).toBe(
    `/handler/cli-auth-confirm?login_code=${loginCode}`,
  );
  await expect(page.getByText("Authorize CLI Application")).not.toBeVisible();
});
