// cmux-web-test-timeout: 600
// l10n-allow-file: browser assertions and artifact names.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("settings-controls-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const entry = "pages.settings-controls";
  const baseline = process.env.SETTINGS_CONTROLS_BASELINE === "1";
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "standard" } });
    if (out) await mkdir(out, { recursive: true });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width = 1000, colorScheme = "light") {
    const page = await browser.newPage({
      viewport: { width, height: 760 },
      deviceScaleFactor: 2,
      reducedMotion: "reduce",
    });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height: 760, colorScheme })}`);
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryReady));
    return page;
  }
  async function capture(page: Page, name: string) {
    if (out) await page.screenshot({ path: path.join(out, `${name}.png`) });
  }
  const row = (key: string) => `[data-row-key="${key}"]`;
  // Rows have no Reset button (standup 2026-11-11): a person resets a row from its title's
  // right-click menu. `enabled` is whether that menu's Reset to Default can be chosen.
  async function resetItem(page: Page, selector: string, enabled: boolean) {
    await page.locator(`${selector} .row-title`).click({ button: "right" });
    await page.waitForFunction((enabled) => {
      const item = [...document.querySelectorAll<HTMLButtonElement>("[role=menu] [role=menuitem]")].find(
        (button) => button.textContent === "Reset to Default" || button.textContent === "Use Theme Color",
      );
      return item !== undefined && (item.disabled || item.getAttribute("aria-disabled") === "true") !== enabled;
    }, enabled);
    return page.locator("[role=menu] [role=menuitem]", { hasText: /^(Reset to Default|Use Theme Color)$/ });
  }

  for (const width of [1000, 480])
    for (const scheme of ["light", "dark"]) {
      test(`switch keyboard/reset keeps its position (${width}, ${scheme})`, async () => {
        const page = await open("standard", width, scheme);
        try {
          const selector = row("history.terminalCommands");
          const toggle = page.locator(`${selector} [role=switch]`);
          await toggle.waitFor();
          await toggle.scrollIntoViewIfNeeded();
          if (!baseline) expect(await toggle.getAttribute("class")).toContain("ui-switch");
          const before = await toggle.boundingBox();
          expect(await toggle.getAttribute("aria-checked")).toBe("false");
          await toggle.focus();
          await page.keyboard.press("Space");
          await page.waitForFunction(
            (s) => document.querySelector(`${s} [role=switch]`)?.getAttribute("aria-checked") === "true",
            selector,
          );
          const changed = await toggle.boundingBox();
          expect(Math.abs(changed!.x - before!.x)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(changed!.y - before!.y)).toBeLessThanOrEqual(0.5);
          await capture(page, `settings-switch-${width}-${scheme}`);
          await (await resetItem(page, selector, true)).click();
          await page.waitForFunction(
            (s) => document.querySelector(`${s} [role=switch]`)?.getAttribute("aria-checked") === "false",
            selector,
          );
          const reset = await toggle.boundingBox();
          expect(Math.abs(reset!.x - before!.x)).toBeLessThanOrEqual(0.5);
          const geometry = await page.locator(selector).evaluate((element) => {
            const style = getComputedStyle(element);
            return {
              padding: parseFloat(style.paddingTop),
              minimum: parseFloat(style.minHeight),
              animations: document.getAnimations().filter((animation) => animation.playState === "running").length,
            };
          });
          if (!baseline) {
            expect(geometry.padding % 4).toBe(0);
            expect(geometry.minimum).toBe(28);
          }
          console.log(
            `SETTINGS_CONTROLS ${JSON.stringify({ width, scheme, toggleShift: Math.abs(changed!.x - before!.x), ...geometry })}`,
          );
        } finally {
          await page.close();
        }
      });
    }

  test("text commits on Enter, rejects invalid input and resets through the store", async () => {
    const page = await open("text");
    try {
      const selector = row("browser.newTabPage");
      const field = page.locator(`${selector} input.text`);
      await field.waitFor();
      const original = await field.inputValue();
      if (!baseline) expect(await field.getAttribute("class")).toContain("ui-input");
      await field.fill("https://example.org/settings");
      await field.press("Enter");
      await (await resetItem(page, selector, true)).waitFor();
      await page.keyboard.press("Escape");
      await field.fill("invalid address");
      await field.press("Enter");
      await page.locator(`${selector} [role=alert]`).waitFor();
      expect(await field.getAttribute("aria-invalid")).toBe("true");
      await (await resetItem(page, selector, true)).click();
      await page.waitForFunction(
        ({ selector, original }) =>
          (document.querySelector(`${selector} input.text`) as HTMLInputElement)?.value === original,
        { selector, original },
      );
      expect(await page.locator(`${selector} [role=alert]`).count()).toBe(0);
      await capture(page, "settings-text-reset");
    } finally {
      await page.close();
    }
  });

  test("managed switch is natively disabled and cannot change", async () => {
    const page = await open("managed");
    try {
      const selector = row("browser.remoteLocalhost");
      const toggle = page.locator(`${selector} [role=switch]`);
      await toggle.waitFor();
      expect(await toggle.isDisabled()).toBe(true);
      expect(await toggle.getAttribute("aria-checked")).toBe("false");
      await toggle.evaluate((element) => (element as HTMLButtonElement).click());
      expect(await toggle.getAttribute("aria-checked")).toBe("false");
      // A managed row cannot be reset either.
      await resetItem(page, selector, false);
      await page.keyboard.press("Escape");
      await capture(page, "settings-managed");
    } finally {
      await page.close();
    }
  });
  test("host theme colors reach labels and shared inputs", async () => {
    const page = await open("text", 480);
    try {
      const selector = row("browser.newTabPage");
      await page.locator(`${selector} input.text`).waitFor();
      await page.evaluate(() => document.documentElement.style.setProperty("--cmux-text", "rgb(12, 34, 56)"));
      const colors = await page
        .locator(selector)
        .evaluate((element) =>
          [element.querySelector(".row-title")!, element.querySelector("input.text")!].map(
            (node) => getComputedStyle(node).color,
          ),
        );
      expect(colors).toEqual(["rgb(12, 34, 56)", "rgb(12, 34, 56)"]);
      if (!baseline) {
        const sidebar = await page.locator(".settings > .sidebar").evaluate((element) => {
          const style = getComputedStyle(element);
          return [style.paddingTop, style.paddingRight, style.paddingBottom, style.paddingLeft].map(parseFloat);
        });
        expect(sidebar).toEqual([12, 12, 8, 12]);
      }
    } finally {
      await page.close();
    }
  });
});
