// cmux-web-test-timeout: 300
// The PR chip's status popover (header/PullRequestChip.tsx) lists each check as a row whose name
// links to its run. The row took its hover wash from anywhere in it (`:has(>a):hover`), while the
// link was only as wide as the check's name: most of the lit row opened nothing on a click.
// Wherever a check row is lit, the pointer is over its link, and the link fills the row's free width
// (rulebook: a hover or press highlight covers only the control it belongs to).
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/pr-status-check-row-target.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("pr-status-check-row-target.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`pr status check rows: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("pr status check rows", () => test("browsers", () => {}));
    return;
  }

  const ENTRY = "agent-pane.header-tools";
  const VARIANT = "pull-request-status";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: VARIANT, frame: "component", width: 760, height: 640, theme })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: [...browsers.values()][0], params: { variant: VARIANT } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, theme: string): Promise<Page> => {
    // Reduced motion: the hover wash applies in the hover's own frame, with no transition to wait out.
    const page = await browsers
      .get(engine)!
      .newPage({ viewport: { width: 760, height: 640 }, reducedMotion: "reduce" });
    await page.goto(stageURL(theme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".acpmux-pr-check > a").first().waitFor();
    return page;
  };

  for (const [engine] of engines)
    for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"])
      test(`${engine}, ${theme}: a lit check row is its link wherever it is lit`, async () => {
        const page = await open(engine, theme);
        const rows = page.locator(".acpmux-pr-check:has(> a)");
        const count = await rows.count();
        expect(count, "the fixture has linked checks").toBeGreaterThan(0);
        let lit = 0;
        for (let index = 0; index < count; index += 1) {
          const box = (await rows.nth(index).boundingBox())!;
          // Across the row: just past the dot, the middle, and near the trailing end.
          for (const x of [box.x + 24, box.x + box.width / 2, box.x + box.width - 10]) {
            const y = box.y + box.height / 2;
            await page.mouse.move(x, y);
            const probe = await rows.nth(index).evaluate(
              (row, point) => {
                const color = getComputedStyle(row).backgroundColor;
                const clear = color === "transparent" || /^rgba\(.*,\s*0\)$/.test(color);
                const hit = document.elementFromPoint(point.x, point.y);
                return { lit: !clear, link: hit?.closest("a") !== null && row.contains(hit) };
              },
              { x, y },
            );
            if (probe.lit) lit += 1;
            expect(
              !probe.lit || probe.link,
              `row ${index} lit at x=${Math.round(x - box.x)} opens its link there`,
            ).toBe(true);
          }
        }
        expect(lit, "a linked check row lights under the pointer").toBeGreaterThan(0);
        await page.close();
      });
});
