// cmux-web-test-timeout: 240
// Every Settings section header ("Window", "Tabs", "Columns", …) starts on the card's left edge, the
// same edge as the page title ("General") above it, on every Settings page, at a wide and a narrow
// pane, in real engines on the settings dev server with the in-memory mock (`?mock`).
// Regression (user, 2026-10-30, NIGHTLY Settings > General): the headers sat 17 px in, on the rows'
// text edge, and read as indented off the cards; asked to left-align them. A header inside a glass
// card (`.group.ui-glass`) sits on that card's surface and keeps the rows' text edge, so it is the
// glass card's edge plus the rows' inset, also checked here.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("settings-header-edge.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
      engines.push(engine);
    } catch {
      console.warn(`settings-header-edge: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";

  beforeAll(async () => {
    if (engines.length === 0) return;
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.settings-page.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    await warmViteServer(vite, "/");
  }, 180_000);

  afterAll(async () => {
    await vite?.close();
  });

  /** Opens `section` and waits until three painted frames in a row show the same layout. */
  const open = async (page: Page, section: string) => {
    await page.goto(`${base}/?mock#/settings/${section}`);
    await page.waitForSelector(".content .section-title");
    await page.evaluate(async () => {
      await document.fonts.ready;
      const layout = () =>
        [...document.querySelectorAll<HTMLElement>(".content .group-title")]
          .map((title) => `${title.offsetTop}:${title.getBoundingClientRect().left}`)
          .join() + ` ${document.querySelector(".content")!.scrollHeight}`;
      await new Promise<void>((resolve) => {
        let last = "";
        let same = 0;
        window.cmuxAfterPaint(() => {
          const now = layout();
          same = now === last ? same + 1 : 0;
          last = now;
          if (same < 2) return true;
          resolve();
          return false;
        });
      });
    });
  };

  /** Each visible header's left edge, with the edge it must start on. */
  const edges = (page: Page) =>
    page.evaluate(() => {
      const page = document.querySelector(".content .section-title")!.getBoundingClientRect().left;
      const out: { header: string; left: number; expected: number }[] = [];
      for (const title of document.querySelectorAll<HTMLElement>(".content .group-title, .content .density-help")) {
        const box = title.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) continue;
        const glass = title.closest<HTMLElement>(".group.ui-glass");
        let expected = page;
        if (glass) {
          // On a glass card the header shares the rows' text edge: the card edge plus a row's
          // left padding.
          const row = glass.querySelector<HTMLElement>(".row");
          const inset = row ? parseFloat(getComputedStyle(row).paddingLeft) : 0;
          expected = glass.getBoundingClientRect().left + inset;
        }
        const text = title.textContent?.trim().slice(0, 40) ?? "";
        out.push({ header: text, left: Math.round(box.left), expected: Math.round(expected) });
      }
      return out;
    });

  const sections = async (page: Page) => {
    await open(page, "general");
    return page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>("[data-section-link]")].map((link) => link.dataset.sectionLink!),
    );
  };

  for (const [name, engine] of engines) {
    describe(name, () => {
      for (const width of [1100, 560]) {
        test(`every section header starts on the page title's edge at ${width} px`, async () => {
          const browser = await engine.launch({ headless: true });
          try {
            const page = await browser.newPage({ viewport: { width, height: 900 } });
            await installPaintedFrames(page);
            const ids = await sections(page);
            expect(ids.length).toBeGreaterThan(5);
            const off: string[] = [];
            let checked = 0;
            for (const id of ids) {
              await open(page, id);
              for (const edge of await edges(page)) {
                checked += 1;
                if (edge.left !== edge.expected)
                  off.push(`${id} "${edge.header}": left ${edge.left}, expected ${edge.expected}`);
              }
            }
            expect(checked).toBeGreaterThan(10);
            expect(off).toEqual([]);
          } finally {
            await browser.close();
          }
        });
      }
    });
  }
  if (engines.length === 0) describe.skip("settings header edge", () => test("engines", () => {}));
});
