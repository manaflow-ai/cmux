// Shell mode is entered by typing `!` into the New Tab composer. The mode prefix is reserved
// before that first key so the textarea does not shift horizontally (onboarding recovery, Leo
// 2026-10-26: the !pwd play must have zero layout shift).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-shell-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-shell-layout: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab shell layout", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/new-tab-picker.html?template=composer");
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(template = "composer"): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 650 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-picker.html?template=${template}`);
    await page.locator(".nt-field").waitFor();
    return page;
  }

  test("the Console prompt keeps a separate prefix column before the text", async () => {
    const page = await open("console");
    const geometry = await page.evaluate(() => {
      const field = document.querySelector<HTMLTextAreaElement>(".nt-field")!;
      const glyph = document.querySelector<HTMLElement>(".nt-prompt-glyph")!;
      return {
        textStart: field.getBoundingClientRect().left + parseFloat(getComputedStyle(field).paddingInlineStart),
        glyphEnd: glyph.getBoundingClientRect().right,
      };
    });
    expect(geometry.textStart - geometry.glyphEnd).toBeGreaterThan(8);
    await page.close();
  });

  test("reserves the shell prefix so !pwd does not shift the field", async () => {
    const page = await open();
    const field = page.locator(".nt-field");
    const before = await field.boundingBox();
    expect(before).not.toBeNull();

    await field.focus();
    await page.evaluate(async () => {
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      const target = window as Window & { shellLayoutShifts?: { value: number; sources: string[] }[] };
      target.shellLayoutShifts = [];
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          const shift = entry as PerformanceEntry & { value: number; sources: { node?: Node }[] };
          target.shellLayoutShifts!.push({
            value: shift.value,
            sources: shift.sources.map(({ node }) => node?.nodeName ?? "unknown"),
          });
        }
      }).observe({ type: "layout-shift" });
    });
    await page.keyboard.type("!pwd");
    await page.locator(".nt-shell-glyph").waitFor();
    const shifts = await page.evaluate(async () => {
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      return (window as Window & { shellLayoutShifts?: { value: number; sources: string[] }[] }).shellLayoutShifts!;
    });
    expect(shifts).toEqual([]);
    const after = await field.boundingBox();
    expect(after).not.toBeNull();

    const delta = {
      x: Math.abs(after!.x - before!.x),
      width: Math.abs(after!.width - before!.width),
    };
    // The DOM geometry is the regression signal behind the onboarding play's CLS budget. A prefix
    // slot is reserved before the first key, so neither edge moves when the shell glyph is shown.
    expect(delta.x).toBeLessThanOrEqual(0.5);
    expect(delta.width).toBeLessThanOrEqual(0.5);
    const glyph = await page.locator(".nt-shell-glyph").boundingBox();
    const plus = await page.locator(".nt-input .acpmux-newtab-plus button").boundingBox();
    expect(glyph).not.toBeNull();
    expect(plus).not.toBeNull();
    expect(glyph!.x).toBeGreaterThanOrEqual(plus!.x + plus!.width);
    await page.close();
  });
});
