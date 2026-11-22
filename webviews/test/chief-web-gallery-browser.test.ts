// l10n-allow-file: browser fixture labels, not shipped UI.
// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chief-web-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "chief-web.mobile", {
      browser,
      params: { variant: "phone-light" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const [variant, width, height, scheme] of [
    ["phone-light", 390, 844, "light"],
    ["phone-dark", 390, 844, "dark"],
    ["tablet", 768, 1024, "light"],
    ["desktop", 1280, 900, "dark"],
    ["empty", 390, 844, "light"],
    ["streaming", 390, 844, "dark"],
    ["expired", 390, 844, "light"],
    ["machine-claude", 390, 844, "light"],
    ["machine-claude-code", 390, 844, "dark"],
    ["machine-codex", 390, 844, "light"],
  ] as const) {
    test(`${variant}: readable transcript and usable composer`, async () => {
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame("chief-web.mobile", { variant, width, height, colorScheme: scheme }));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.getByTestId("chief-web").waitFor();
        if (variant === "expired") await page.getByRole("button", { name: "Sign in again" }).waitFor();
        else {
          const field = page.getByRole("textbox", { name: "Message your Chief" });
          await field.waitFor();
          if (variant === "empty")
            await page.getByRole("heading", { name: "Ask your Chief to build something" }).waitFor();
          else if (variant === "streaming")
            await page.getByText("I’m building your hello page.", { exact: false }).waitFor();
          else await page.getByRole("link", { name: "Open your page" }).waitFor();
          if (variant.startsWith("machine")) {
            const card = page.getByTestId("chief-machine-login");
            await card.waitFor();
            if (variant === "machine-claude")
              await card.getByRole("button", { name: "Sign in to Claude", exact: true }).waitFor();
            else await card.getByRole("link", { name: "Open sign-in page" }).waitFor();
            const box = await card.boundingBox();
            expect(box!.x).toBeGreaterThanOrEqual(0);
            expect(box!.x + box!.width).toBeLessThanOrEqual(width);
            expect(box!.y + box!.height).toBeLessThanOrEqual(height);
          }
          const layout = await field.evaluate((element) => ({
            font: parseFloat(getComputedStyle(element).fontSize),
            bottom: element.getBoundingClientRect().bottom,
            width: document.documentElement.scrollWidth,
            viewport: innerWidth,
          }));
          expect(layout.font).toBeGreaterThanOrEqual(16);
          expect(layout.bottom).toBeLessThanOrEqual(height);
          expect(layout.width).toBe(layout.viewport);
          if (variant === "phone-light") {
            await field.fill("A draft kept while the keyboard opens");
            await field.press("Enter");
            expect(await field.inputValue()).toContain("\n");
            await page.setViewportSize({ width, height: 480 });
            await page.waitForFunction(() => document.querySelector("textarea")!.getBoundingClientRect().bottom <= 480);
            await page.setViewportSize({ width, height });
            await field.fill("");
          }
        }
        if (process.env.FAST_CHECKS_OUT) {
          await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
          await page.screenshot({
            path: path.join(process.env.FAST_CHECKS_OUT, `chief-web-${variant}.png`),
          });
        }
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
