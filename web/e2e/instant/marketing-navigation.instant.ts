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

test("locale navigation refreshes content and metadata after the URL changes", async ({ page }) => {
  await page.goto("/ko");
  const language = page.locator('select[aria-label="Language"]').first();

  await language.selectOption("en");
  await page.waitForURL((url) => url.pathname === "/");
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(language).toHaveValue("en");
  await expect(page).toHaveTitle("cmux - The terminal built for multitasking");
  await expect(page.getByRole("heading", { name: "Features" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "기능" })).toHaveCount(0);

  await language.selectOption("ko");
  await page.waitForURL((url) => url.pathname === "/ko");
  await expect(page.locator("html")).toHaveAttribute("lang", "ko");
  await expect(language).toHaveValue("ko");
  await expect(page).toHaveTitle("cmux — 멀티태스킹을 위해 만든 터미널");
  await expect(page.getByRole("heading", { name: "기능" })).toBeVisible();

  await language.selectOption("ja");
  await page.waitForURL((url) => url.pathname === "/ja");
  await expect(page.locator("html")).toHaveAttribute("lang", "ja");
  await expect(language).toHaveValue("ja");
  await expect(page).toHaveTitle("cmux - マルチタスクのために作られたターミナル");
  await expect(page.getByRole("heading", { name: "機能" })).toBeVisible();

  await page.reload();
  await expect(page).toHaveTitle("cmux - マルチタスクのために作られたターミナル");
  await expect(page.getByRole("heading", { name: "機能" })).toBeVisible();
});
