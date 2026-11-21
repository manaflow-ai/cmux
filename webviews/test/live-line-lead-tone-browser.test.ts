// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The live line's action word ("Writing", "Using repo", "Running") reads in the line's own muted
// tone, never brighter than the words after it (Leo, 2026-11-07: "The, like, white text, the verb,
// or whatever the ing verb, why is it white? ... don't make it white"). The same holds for a
// permission ask's verb ("Run" before its command), which sat in full ink over its quieter row.
// Takes back #33241's full-ink lead. Measured in real Chromium on the shipped gallery stages, with
// the motion on (the shimmer's dim base) and off (the plain muted line).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("live-line-lead-tone-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("live line lead tone", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.claude-code-tool-rows", {
      browser,
      params: { variant: "shipped" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, motion: "reduce" | "no-preference") => {
    const page = await browser.newPage({ viewport: { width: 760, height: 900 } });
    await page.emulateMedia({ reducedMotion: motion });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Each lead's colour beside the colour of the words around it (its parent's). */
  const pairs = (page: Awaited<ReturnType<typeof open>>, lead: string) =>
    page.evaluate((selector) => {
      return [...document.querySelectorAll<HTMLElement>(selector)].map((element) => ({
        text: element.textContent ?? "",
        lead: getComputedStyle(element).color,
        line: getComputedStyle(element.parentElement!).color,
      }));
    }, lead);

  for (const motion of ["no-preference", "reduce"] as const)
    test(`the live line's action reads in the line's tone (motion ${motion})`, async () => {
      const page = await open("agent-pane.claude-code-tool-rows", "shipped", motion);
      const found = await pairs(page, ".cv-thinking .cv-worked__lead");
      await page.close();
      expect(found.length).toBeGreaterThan(0);
      for (const pair of found)
        expect({ text: pair.text, color: pair.lead }).toEqual({
          text: pair.text,
          color: pair.line,
        });
    });

  test("a permission ask's verb reads in its row's tone", async () => {
    const page = await open("agent-pane.permission-panel", "pending", "reduce");
    const found = await pairs(page, ".acpmux-ask-verb");
    await page.close();
    expect(found.length).toBeGreaterThan(0);
    for (const pair of found)
      expect({ text: pair.text, color: pair.lead }).toEqual({ text: pair.text, color: pair.line });
  });
});
