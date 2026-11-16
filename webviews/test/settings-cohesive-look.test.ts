// cmux-web-test-timeout: 240
// Settings reads as one surface, laid out like a desktop app's settings (user, 2026-10-30: "make
// settings better, make it look like this" with ChatGPT's Settings; and "we need everything to be
// cohesive with same bg color"). In real engines, on the settings dev server with the mock:
// - one background under the content: the content pane paints no fill of its own. The sidebar takes
//   the window sidebar's fill (none by default: the app's sidebar is the window's color; Lucas
//   2026-11-12, after Lawrence); the content is a panel beside it with rounded left corners and no line
//   between them, only the two fills, as the window's main pane beside the app sidebar (Lucas 2026-11-12);
// - the sidebar opens with the page's title ("Settings") above the search field;
// - the content is one centered column of at most 680 px;
// - a row's description wraps at about 60% of the card, leaving the right side to the control.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("settings-cohesive-look.test.ts", async () => {
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
      console.warn(`settings-cohesive-look: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
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

  const open = async (page: Page, section: string) => {
    await page.goto(`${base}/?mock#/settings/${section}`);
    await page.waitForSelector(".content .section-title");
    await page.evaluate(async () => {
      await document.fonts.ready;
      await new Promise<void>((resolve) => {
        let frames = 0;
        window.cmuxAfterPaint(() => {
          frames += 1;
          if (frames < 3) return true;
          resolve();
          return false;
        });
      });
    });
  };

  const measure = (page: Page) =>
    page.evaluate(() => {
      const alpha = (color: string) => {
        if (color === "transparent") return 0;
        const match = color.match(/rgba?\(([^)]+)\)/) ?? color.match(/srgb ([^)]+)\)/);
        if (!match) return 1;
        const parts = match[1]!.split(/[\s,/]+/).filter(Boolean);
        return parts.length >= 4 ? Number(parts[3]) : 1;
      };
      const sidebar = document.querySelector<HTMLElement>(".settings > .sidebar")!;
      const content = document.querySelector<HTMLElement>(".settings > .content")!;
      const column = content.querySelector<HTMLElement>(".column")!;
      const sidebarStyle = getComputedStyle(sidebar);
      const contentBox = content.getBoundingClientRect();
      const columnBox = column.getBoundingClientRect();
      const contentInner = contentBox.width - (content.offsetWidth - content.clientWidth);
      const helps: string[] = [];
      for (const help of document.querySelectorAll<HTMLElement>(".content .rows .row .row-help")) {
        const row = help.closest<HTMLElement>(".row")!;
        const ratio = help.getBoundingClientRect().width / row.getBoundingClientRect().width;
        if (ratio > 0.66) helps.push(`${help.textContent?.slice(0, 30)}: ${ratio.toFixed(2)}`);
      }
      return {
        sidebarFill: alpha(sidebarStyle.backgroundColor),
        contentFill: alpha(getComputedStyle(content).backgroundColor),
        sidebarDivider: parseFloat(sidebarStyle.borderRightWidth),
        panelEdge: parseFloat(getComputedStyle(sidebar.parentElement!, "::before").borderLeftWidth) || 0,
        panelCorner: parseFloat(getComputedStyle(sidebar.parentElement!, "::before").borderTopLeftRadius),
        panelOnSidebarEdge:
          Math.abs(
            parseFloat(getComputedStyle(sidebar.parentElement!, "::before").left) -
              sidebar.getBoundingClientRect().width,
          ) <= 0.5,
        title: sidebar.querySelector<HTMLElement>(".sidebar-title")?.textContent?.trim() ?? null,
        titleAboveSearch:
          (sidebar.querySelector(".sidebar-title")?.getBoundingClientRect().bottom ?? Infinity) <=
          sidebar.querySelector(".search-bar")!.getBoundingClientRect().top,
        columnWidth: Math.round(columnBox.width),
        leftGap: Math.round(columnBox.left - contentBox.left),
        rightGap: Math.round(contentBox.left + contentInner - columnBox.right),
        wideHelps: helps,
      };
    });

  for (const [name, engine] of engines) {
    describe(name, () => {
      test("Settings is one surface with a titled sidebar and a centered 680 px column", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage({ viewport: { width: 1300, height: 900 } });
          await installPaintedFrames(page);
          for (const section of ["general", "appearance", "notifications"]) {
            await open(page, section);
            const look = await measure(page);
            expect({ section, contentFill: look.contentFill }).toEqual({ section, contentFill: 0 });
            // The window sidebar's fill: none on the dev server (no sidebar color, no separate shade).
            expect(look.sidebarFill).toBe(0);
            expect(look.sidebarDivider).toBe(0);
            expect(look.panelEdge).toBe(0);
            expect(look.panelCorner).toBeGreaterThan(0);
            expect(look.panelOnSidebarEdge).toBe(true);
            expect(look.title).toBe("Settings");
            expect(look.titleAboveSearch).toBe(true);
            expect(look.columnWidth).toBeLessThanOrEqual(680);
            expect(Math.abs(look.leftGap - look.rightGap)).toBeLessThanOrEqual(2);
            expect(look.wideHelps).toEqual([]);
          }
        } finally {
          await browser.close();
        }
      });
    });
  }
  if (engines.length === 0) describe.skip("settings cohesive look", () => test("engines", () => {}));
});
