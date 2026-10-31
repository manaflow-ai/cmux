// cmux-web-test-timeout: 300
// The New Tab page's lists (Open tabs, Recently closed, All chats) share one leading column: each
// list's heading text and every row's first ink (its glyph) start the same distance in from the
// list's edge, the shared row inset (`--ui-row-padding-inline`, 8 at 100%). Open tabs and Recently
// closed rows started their glyphs 2px left of their own heading, and All chats sat 2px further in
// than both, on an off-grid 10 (design/grid.md rules 1, 2 and 6: "Every row type starts content on
// its surface's lead/text ... no row type picks its own inset"; Leo 2026-10-29: "We need to have the
// fucking shit aligned on fucking grids and lines").
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-list-columns.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-list-columns.test.ts", async () => {
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
      console.warn(`new tab list columns: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab list columns", () => test("browsers", () => {}));
    return;
  }

  // Each case: a gallery state, its list, the list's heading text and its rows' first ink.
  const cases = [
    {
      name: "Open tabs",
      entry: "agent-pane.new-tab",
      variant: "split-open-tabs",
      frame: "component",
      list: ".nt-open-tabs:not(.nt-closed)",
      heading: ".nt-open-tabs-head",
      glyph: ".nt-open-tab .nt-row-glyph",
    },
    {
      name: "Recently closed",
      entry: "agent-pane.new-tab",
      variant: "recently-closed",
      frame: "component",
      list: ".nt-closed",
      heading: ".nt-open-tabs-head",
      glyph: ".nt-open-tab .nt-row-glyph",
    },
    {
      name: "All chats",
      entry: "agent-pane.all-chats-list",
      variant: "page-empty",
      frame: "component",
      list: ".nt-all",
      heading: ".nt-chats-head .nt-chats-tab",
      glyph: ".nt-all-row .nt-all-glyph",
    },
  ] as const;

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const port = () => (vite!.httpServer!.address() as { port: number }).port;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ["agent-pane.new-tab", "agent-pane.all-chats-list"], {
      browser: [...browsers.values()][0],
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, c: (typeof cases)[number]): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 900 } });
    await page.goto(
      `http://127.0.0.1:${port()}${galleryFrame(c.entry, { variant: c.variant, frame: c.frame, width: 820, theme: "Catppuccin Mocha" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(c.glyph).first().waitFor();
    return page;
  };

  for (const [engine] of engines)
    for (const c of cases)
      test(`${engine}, ${c.name}: the heading and every row's glyph start on the shared row inset`, async () => {
        const page = await open(engine, c);
        const geometry = await page.evaluate(
          ({ list, heading, glyph }) => {
            const root = document.querySelector<HTMLElement>(list)!;
            const left = root.getBoundingClientRect().left;
            const range = document.createRange();
            range.selectNodeContents(root.querySelector(heading)!);
            // The shared row inset, resolved by the engine (it scales with the interface size).
            const probe = document.createElement("div");
            probe.style.paddingLeft = "var(--ui-row-padding-inline)";
            root.append(probe);
            const inset = parseFloat(getComputedStyle(probe).paddingLeft);
            probe.remove();
            return {
              inset,
              heading: range.getBoundingClientRect().left - left,
              glyphs: [...root.querySelectorAll(glyph)].map((element) => element.getBoundingClientRect().left - left),
            };
          },
          { list: c.list, heading: c.heading, glyph: c.glyph },
        );
        expect(geometry.inset, "the shared row inset resolves").toBe(8);
        expect(geometry.glyphs.length, "the list has rows").toBeGreaterThan(0);
        expect(Math.abs(geometry.heading - geometry.inset), "the heading starts on the row inset").toBeLessThan(0.5);
        for (const x of geometry.glyphs)
          expect(Math.abs(x - geometry.inset), "a row's glyph starts on the row inset").toBeLessThan(0.5);
        await page.close();
      });
});
