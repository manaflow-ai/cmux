// l10n-allow-file: gallery fixture labels and browser assertions.
// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("kit-row-actions-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let url: string;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    const entry = "kit.primitives";
    const params = { variant: "primitives" };
    await warmGalleryFrame(vite, entry, { browser, params });
    const port = (vite.httpServer!.address() as { port: number }).port;
    url = `http://127.0.0.1:${port}${galleryFrame(entry, params)}`;
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const style = (el: Locator, prop: string) =>
    el.evaluate((node, key) => getComputedStyle(node).getPropertyValue(key), prop);

  for (const width of [360, 760]) {
    test(`an Inbox action overlays the text at ${width}px and activates independently`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 800 } });
      try {
        await page.goto(url);
        const panel = page.locator('[data-scheme="light"]');
        const list = panel.locator(".kit-list").first();
        const row = list.locator("li").first();
        const primary = row.locator("button.kit-row");
        const action = row.getByRole("button", { name: "Pin Inbox" });
        const strip = row.locator(".kit-row-actions");
        const text = row.locator(".kit-row-text");
        const badge = row.locator(".kit-row-trail");
        const receipt = panel.getByTestId("kit-receipt-light");
        await action.waitFor({ state: "attached" });
        await page.mouse.move(0, 0);
        expect(await primary.getByRole("button").count()).toBe(0);
        expect(await style(strip, "opacity")).toBe("0");
        expect(parseFloat(await style(text, "--ui-reveal-cover"))).toBe(0);
        const before = (await text.boundingBox())!;
        const stripBox = (await strip.boundingBox())!;
        const badgeBox = (await badge.boundingBox())!;
        expect(before.x + before.width).toBeCloseTo(stripBox.x + stripBox.width, 0);
        expect(stripBox.x + stripBox.width).toBeLessThanOrEqual(badgeBox.x);
        await text.hover();
        await page.waitForFunction(() => {
          const el = document.querySelector(".kit-row-actions")!;
          const text = document.querySelector(".kit-row-text.ui-reveal-text")!;
          return (
            getComputedStyle(el).opacity === "1" &&
            parseFloat(getComputedStyle(text).getPropertyValue("--ui-reveal-cover")) >=
              el.getBoundingClientRect().width - 0.5
          );
        });
        expect(await text.boundingBox()).toEqual(before);
        expect(await badge.boundingBox()).toEqual(badgeBox);
        await list.getByRole("button", { name: /Review queue/ }).click();
        await page.mouse.move(0, 0);
        await page.waitForFunction(() => getComputedStyle(document.querySelector(".kit-row-actions")!).opacity === "0");
        await page.keyboard.press("Shift+Tab");
        expect(await action.evaluate((el) => el.matches(":focus-visible"))).toBe(true);
        expect(await style(strip, "opacity")).toBe("1");
        await page.keyboard.press("Enter");
        expect(await receipt.textContent()).toBe("review · pin");
        await page.keyboard.press("Shift+Tab");
        expect(await primary.evaluate((el) => el.matches(":focus-visible"))).toBe(true);
        await page.keyboard.press("Enter");
        expect(await receipt.textContent()).toBe("inbox · pin");
      } finally {
        await page.close();
      }
    });
  }

  test("an RTL action covers the left end of the text and leaves the badge clear", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 800 } });
    try {
      await page.goto(url);
      const row = page.locator('[data-scheme="light"] .kit-row-item').first();
      await row.evaluate((el) => el.setAttribute("dir", "rtl"));
      const text = row.locator(".kit-row-text");
      const strip = row.locator(".kit-row-actions");
      const badge = row.locator(".kit-row-trail");
      await strip.hover();
      const textBox = (await text.boundingBox())!;
      const actionBox = (await strip.boundingBox())!;
      const badgeBox = (await badge.boundingBox())!;
      expect(textBox.x).toBeCloseTo(actionBox.x, 0);
      expect(badgeBox.x + badgeBox.width).toBeLessThanOrEqual(actionBox.x);
      expect(await style(text, "mask-image")).toContain("to right");
    } finally {
      await page.close();
    }
  });

  test("a touch row shows its action and masks its text before the first tap", async () => {
    const page = await browser.newPage({ viewport: { width: 390, height: 800 }, hasTouch: true });
    try {
      await page.goto(url);
      const panel = page.locator('[data-scheme="dark"]');
      const action = panel.getByRole("button", { name: "Pin Inbox" });
      await action.waitFor();
      expect(await page.evaluate(() => matchMedia("(hover: none)").matches)).toBe(true);
      expect(await style(panel.locator(".kit-row-actions"), "opacity")).toBe("1");
      expect(parseFloat(await style(panel.locator(".ui-reveal-text"), "--ui-reveal-cover"))).toBeGreaterThan(0);
      await action.tap();
      expect(await panel.getByTestId("kit-receipt-dark").textContent()).toBe("inbox · pin");
    } finally {
      await page.close();
    }
  });
});
