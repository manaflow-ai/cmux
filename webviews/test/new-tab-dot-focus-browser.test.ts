// cmux-web-test-timeout: 180
// Real radios and shipped dot styles: names must outlive the pick timer while keyboard-focused.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-dot-focus-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const before = process.env.CMUX_DOT_BEFORE === "1";
  const captures = process.env.CMUX_DOT_CAPTURES;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "new-tab.dot-focus", { browser });
    if (captures) mkdirSync(captures, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const scheme of ["light", "dark"] as const) {
    for (const width of [340, 760]) {
      test(`${scheme}, ${width}px: keyboard labels and pointer focus return`, async () => {
        const page = await browser.newPage({
          viewport: { width, height: 240 },
          colorScheme: scheme,
          reducedMotion: width === 340 ? "reduce" : "no-preference",
        });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("new-tab.dot-focus", {
              width,
              colorScheme: scheme,
              reducedMotion: width === 340 ? 1 : 0,
              theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const label = page.locator(".nt-style-name");
          const first = page.getByRole("radio", { name: "Minimal", exact: true });
          const second = page.getByRole("radio", { name: "Quick actions", exact: true });
          const third = page.getByRole("radio", { name: "Compact", exact: true });
          const shown = () => label.evaluate((node) => node.hasAttribute("data-shown"));
          await page.getByRole("button", { name: "Before dots" }).click();
          // A stationary pointer elsewhere must not hide a freshly keyboard-focused name.
          await third.hover();
          await page.keyboard.press("Tab");
          expect(await first.evaluate((node) => node === document.activeElement)).toBe(true);
          if (!before) expect(await label.textContent()).toBe("Minimal");
          await page.mouse.move(1, 1);
          expect(await shown()).toBe(!before);
          if (captures)
            await page.screenshot({
              path: path.join(captures, `${before ? "before" : "after"}-${scheme}-${width}-tab.png`),
            });

          // Clicking the already-selected radio has no change event or focus-return callback.
          // Its name must still go away when the pointer leaves, then reappear on the next key.
          await first.click();
          await page.mouse.move(1, 1);
          expect(await shown()).toBe(false);
          await page.keyboard.press("ArrowRight");
          await page.waitForFunction(
            () => document.querySelector<HTMLInputElement>('input[value="Quick actions"]')?.checked,
          );
          // fixed-wait: observe beyond the 1100ms pick timer to test retained focus, not selection feedback.
          await page.waitForTimeout(1400);
          expect(await second.evaluate((node) => node === document.activeElement)).toBe(true);
          expect(await shown()).toBe(!before);
          if (!before) expect(await label.textContent()).toBe("Quick actions");
          if (captures)
            await page.screenshot({
              path: path.join(captures, `${before ? "before" : "after"}-${scheme}-${width}-arrow.png`),
            });
          await page.keyboard.press("Tab");
          expect(await shown()).toBe(false);

          await third.hover();
          expect(await label.textContent()).toBe("Compact");
          expect(await shown()).toBe(true);
          await third.click();
          await page.waitForFunction(() => document.activeElement?.textContent === "Before dots");
          await page.mouse.move(1, 1);
          expect(await shown()).toBe(true);
          // fixed-wait: verify the pointer pick name expires after its 1100ms timer.
          await page.waitForTimeout(1400);
          expect(await shown()).toBe(false);
        } finally {
          await page.close();
        }
      });

      test(`${scheme}, ${width}px: immediate keyboard blur clears the name`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 240 } });
        try {
          await page.clock.install({ time: new Date("2026-01-01T00:00:00Z") });
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("new-tab.dot-focus", {
              width,
              colorScheme: scheme,
              reducedMotion: width === 340 ? 1 : 0,
              theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const label = page.locator(".nt-style-name");
          await page.getByRole("button", { name: "Before dots" }).click();
          await page.mouse.move(1, 1);
          await page.keyboard.press("Tab");
          // Freeze before selection so browser round trips cannot expire the 1100ms pick timer.
          // The gallery stubs Date.now for fixture data; use the installed clock's own epoch.
          await page.clock.pauseAt(new Date("2026-01-02T00:00:00Z"));
          await page.keyboard.press("ArrowRight");
          // Advance only the post-pick focus frame, then hold time through Tab and its assertions.
          await page.clock.runFor(32);
          expect(await page.getByRole("radio", { name: "Quick actions", exact: true }).isChecked()).toBe(true);
          await label.evaluate(async (node) => {
            await Promise.all(node.getAnimations().map((animation) => animation.finished));
          });
          expect(await label.evaluate((node) => getComputedStyle(node).opacity)).toBe("1");
          await page.keyboard.press("Tab");
          const result = await page.evaluate(() => ({
            active: document.activeElement?.textContent,
            shown: document.querySelector(".nt-style-name")!.hasAttribute("data-shown"),
            reduced: matchMedia("(prefers-reduced-motion: reduce)").matches,
          }));
          console.log("dot-immediate-blur", JSON.stringify({ scheme, width, ...result }));
          expect(result.active).toBe("After dots");
          expect(result.reduced).toBe(width === 340);
          expect(result.shown).toBe(false);
          await label.evaluate(async (node) => {
            await Promise.all(node.getAnimations().map((animation) => animation.finished));
          });
          expect(await label.evaluate((node) => getComputedStyle(node).opacity)).toBe("0");
        } finally {
          await page.close();
        }
      });
    }
  }
});
