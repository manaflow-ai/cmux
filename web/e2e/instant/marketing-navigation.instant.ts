import { expect, test } from "@playwright/test";
import { instant } from "@next/playwright";

test("blog navigation commits meaningful UI immediately", async ({ page }) => {
  await page.goto("/");

  await instant(page, async () => {
    await page.locator('a[href="/blog"]').first().click();
    await page.waitForURL((url) => url.pathname === "/blog");
    await expect(page.getByRole("heading", { name: "Blog" })).toBeVisible();
  });
});
