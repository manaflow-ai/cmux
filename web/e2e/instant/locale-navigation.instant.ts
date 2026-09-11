import { expect, test, type Page } from "@playwright/test";

const languages = {
  en: { title: "cmux - The terminal built for multitasking", heading: "Features" },
  ko: { title: "cmux — 멀티태스킹을 위해 만든 터미널", heading: "기능" },
  ja: { title: "cmux - マルチタスクのために作られたターミナル", heading: "機能" },
  ar: { title: "cmux — المحطة الطرفية المصممة لتعدد المهام", heading: "الميزات" },
} as const;

type TestLocale = keyof typeof languages;
const suffix = "?ref=locale-test#locale-check";

test.use({ extraHTTPHeaders: { "Accept-Language": "ko-KR,ko;q=0.9,en;q=0.8" } });

async function expectHomeLocale(page: Page, locale: TestLocale, checkCookie = true) {
  const pathname = locale === "en" ? "/" : `/${locale}`;
  await expect(page).toHaveURL((url) => url.pathname === pathname && url.search + url.hash === suffix);
  await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue(locale);
  await expect(page).toHaveTitle(languages[locale].title);
  await expect(page.locator("html")).toHaveAttribute("lang", locale);
  await expect(page.locator("html")).toHaveAttribute("dir", locale === "ar" ? "rtl" : "ltr");
  await expect(page.getByRole("heading", { name: languages[locale].heading, exact: true })).toBeVisible();
  await page.waitForLoadState("load");
  if (checkCookie) {
    await expect.poll(async () => (await page.context().cookies(page.url()))
      .find((cookie) => cookie.name === "NEXT_LOCALE")?.value).toBe(locale);
  }
}

for (const initialLocale of ["ko", "ja", "ar"] as const) {
  test(`locale ${initialLocale} ↔ English keeps the cookie, URL, document and content together across reloads`, async ({ page }) => {
    test.setTimeout(60_000);
    await page.goto(`/${initialLocale}${suffix}`);
    // An initial visit can use Accept-Language without setting a preference.
    await expectHomeLocale(page, initialLocale, false);

    // Revisit English after each locale to exercise a warm route cache. The
    // Korean Accept-Language preference must not override explicit English.
    for (const locale of ["en", initialLocale, "en"] as const) {
      await page.getByRole("combobox", { name: "Language", exact: true }).selectOption(locale);
      await expectHomeLocale(page, locale);
      await page.reload();
      await expectHomeLocale(page, locale);
    }
  });
}

test("locale switch preserves a nested route after client-side navigation", async ({ page }) => {
  await page.goto("/ko");
  await page.waitForLoadState("load");
  await page.evaluate(() => Reflect.set(window, "localeNavigationMarker", true));
  await page.locator('a[href="/ko/blog"]').first().click();
  await expect(page).toHaveURL((url) => url.pathname === "/ko/blog");
  await expect(page.getByRole("heading", { name: "블로그", exact: true })).toBeVisible();
  expect(await page.evaluate(() => Reflect.get(window, "localeNavigationMarker"))).toBe(true);

  // Preserve caller query parameters and fragment through the locale change.
  await page.evaluate((value) => history.replaceState(null, "", location.pathname + value), suffix);
  await page.waitForLoadState("load");
  await page.getByRole("combobox", { name: "Language", exact: true }).selectOption("en");
  await expect(page).toHaveURL((url) => url.pathname === "/blog" && url.search + url.hash === suffix);
  await expect(page.getByRole("heading", { name: "Blog", exact: true })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(page.getByRole("combobox", { name: "Language", exact: true })).toHaveValue("en");
  await page.waitForLoadState("load");
  await expect.poll(async () => (await page.context().cookies(page.url()))
    .find((cookie) => cookie.name === "NEXT_LOCALE")?.value).toBe("en");
  const title = await page.title();
  await page.reload();
  await expect(page).toHaveURL((url) => url.pathname === "/blog" && url.search + url.hash === suffix);
  await expect(page.getByRole("heading", { name: "Blog", exact: true })).toBeVisible();
  await expect(page).toHaveTitle(title);
});
