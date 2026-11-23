// l10n-allow-file: test fixtures, not shipped UI.
// A file's bar shows its path and its "+N -N" (a1315's cuts, 2026-11-20: "Per-file header: path and
// +/- counts only; file buttons on header hover"). The Viewed eye and the "..." menu show while the
// pointer is on the bar or the keyboard is in it, and a viewed file keeps its eye: it says the file is
// done.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("diff-file-header-hover.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("diff-file-header-hover: skipping (run `bunx playwright install chromium`)");
    describe.skip("diff file header hover", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/diff-toolbar-narrow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the file bar's buttons show on hover and focus; its path and counts always", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html`);
    const header = page.locator(".file-header").first();
    await header.waitFor();
    const opacity = () =>
      page.evaluate(() => {
        const of = (selector: string) => getComputedStyle(document.querySelector(selector)!).opacity;
        return {
          eye: of(".file-header .file-review-viewed"),
          menu: of(".file-header .file-header-menu-button"),
          path: of(".file-header .file-header-path"),
          counts: of(".file-header .file-header-stats"),
        };
      });
    await page.mouse.move(5, 590);
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".file-review-viewed")!).opacity === "0");
    expect(await opacity()).toEqual({ eye: "0", menu: "0", path: "1", counts: "1" });
    await header.hover();
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".file-review-viewed")!).opacity === "1");
    expect(await opacity()).toEqual({ eye: "1", menu: "1", path: "1", counts: "1" });
    await page.mouse.move(5, 590);
    await page.locator(".file-header .file-review-viewed").focus();
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".file-review-viewed")!).opacity === "1");
    expect((await opacity()).menu).toBe("1");
    await page.close();
  });

  test("a viewed file keeps its eye without hover", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/diff-toolbar-narrow.html`);
    const eye = page.locator(".file-header .file-review-viewed").first();
    await eye.waitFor({ state: "attached" });
    await eye.click({ force: true });
    await page.waitForFunction(
      () => document.querySelector(".file-header .file-review-viewed")?.getAttribute("aria-pressed") === "true",
    );
    await page.mouse.move(5, 590);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.waitForFunction(
      () => getComputedStyle(document.querySelector(".file-header .file-header-menu-button")!).opacity === "0",
    );
    expect(await eye.evaluate((element) => getComputedStyle(element).opacity)).toBe("1");
    await page.close();
  });
});
