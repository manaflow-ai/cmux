// The New Tab quick-action strip stays inside its anchored suggestions popover when a pane is
// narrow. The optional capture directory produces the review's before/after pair: before uses
// the old non-wrapping rule, after uses the shipped CSS.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-strip-overflow.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    throw new Error("Chromium is required for the New Tab strip geometry lane");
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let page: Page | undefined;
  const captureDir = process.env.CMUX_UI_CAPTURE_DIR;
  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", {
      variant: "suggestions-ff",
      frame: "component",
      width: 320,
      height: 620,
      locale: "fr",
      theme: "Catppuccin Mocha",
    })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "suggestions-ff" } });
  });

  afterAll(async () => {
    await page?.close();
    await browser?.close();
    await vite?.close();
  });

  test("French create labels fit a 260px suggestions popover", async () => {
    page = await browser!.newPage({ viewport: { width: 320, height: 620 } });
    await page.goto(url());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".nt-create-strip-item").first().waitFor();
    const result = await page.evaluate(() => {
      const rows = document.querySelector<HTMLElement>(".nt-rows")!;
      const viewport = rows.getBoundingClientRect();
      const items = [...rows.querySelectorAll<HTMLElement>(".nt-create-strip-item")];
      return {
        scrollWidth: rows.scrollWidth,
        clientWidth: rows.clientWidth,
        items: items.map((item) => {
          const rect = item.getBoundingClientRect();
          const glyph = item.querySelector<HTMLElement>(".nt-row-glyph")?.getBoundingClientRect();
          return {
            left: rect.left,
            right: rect.right,
            top: rect.top,
            width: rect.width,
            text: item.textContent,
            label: item.getAttribute("aria-label"),
            title: item.getAttribute("title"),
            role: item.getAttribute("role"),
            glyphWidth: glyph?.width ?? 0,
          };
        }),
        viewport: { left: viewport.left, right: viewport.right },
      };
    });
    expect(result.items).toHaveLength(3);
    const first = result.items[0]!;
    expect(first.role).toBe("option");
    expect(first.top).toBeCloseTo(result.items[1]!.top, 0);
    expect(first.top).toBeCloseTo(result.items[2]!.top, 0);
    for (const item of result.items) {
      expect(item.width).toBeGreaterThan(0);
      expect(item.glyphWidth).toBeGreaterThan(0);
      expect(item.label).toBe(item.text);
      expect(item.title).toBe(item.text);
    }
    expect(result.scrollWidth).toBeLessThanOrEqual(result.clientWidth + 1);
    for (const item of result.items) {
      expect(item.left).toBeGreaterThanOrEqual(result.viewport.left - 1);
      expect(item.right).toBeLessThanOrEqual(result.viewport.right + 1);
    }

    if (captureDir) {
      await mkdir(captureDir, { recursive: true });
      await page.evaluate(() => {
        const strip = document.querySelector<HTMLElement>(".nt-create-strip")!;
        strip.style.flexWrap = "nowrap";
        strip.style.overflow = "visible";
        for (const item of strip.querySelectorAll<HTMLElement>(".nt-create-strip-item")) {
          item.style.flex = "0 0 auto";
          item.style.minWidth = "auto";
          item.querySelector<HTMLElement>(".nt-row-title")!.style.cssText = "max-width:none;overflow:visible";
        }
      });
      await page.screenshot({ path: path.join(captureDir, "new-tab-strip-before.png"), animations: "disabled" });
      await page.evaluate(() => {
        const strip = document.querySelector<HTMLElement>(".nt-create-strip")!;
        strip.style.flexWrap = "";
        strip.style.overflow = "";
        for (const item of strip.querySelectorAll<HTMLElement>(".nt-create-strip-item")) {
          item.style.flex = "";
          item.style.minWidth = "";
          item.querySelector<HTMLElement>(".nt-row-title")!.style.cssText = "";
        }
      });
      await page.screenshot({ path: path.join(captureDir, "new-tab-strip-after.png"), animations: "disabled" });
    }
  });
});
