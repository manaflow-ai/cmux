// cmux-web-test-timeout: 240
// Settings reads as one surface, laid out like a desktop app's settings (user, 2026-10-30: "make
// settings better, make it look like this" with ChatGPT's Settings; and "we need everything to be
// cohesive with same bg color"). In real engines, on the settings dev server with the mock:
// - one background under the content: the content pane paints no fill of its own. The sidebar takes
//   the window sidebar's fill (none by default: the app's sidebar is the window's color; Lucas
//   2026-11-12, after Lawrence); the content is a panel beside it with rounded left corners and no line
//   between them, only the two fills, as the window's main pane beside the app sidebar (Lucas 2026-11-12);
// - the sidebar has no title (Lawrence 2026-11-23: "remove settings header, align things better like
//   the search input with the h1"): the search field opens it, its middle on the page title's middle,
//   its box on the row pills' edge, its magnifier on the row icons' column, its text on the row names;
// - the content is one centered column of at most 680 px;
// - a row's description wraps at about 60% of the card, leaving the right side to the control (a row
//   with no control may run its text the full width).
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
      // A section switch (a hash change: the old section's title still matches the wait above) slides the
      // new page in from 4 px down (layout.css settings-enter): measure at rest, or a slow machine reads
      // the title 4 px off the search field.
      await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => {})));
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
        // A row of text alone (the Customization Library's lead line, in Appearance since 75d22c950b6)
        // has no control to leave the right side to.
        if (!row.querySelector("button, input, select, textarea, [role=switch], [role=combobox]")) continue;
        // A help alone in its row is a note across the row (Customization Library's "Where two
        // entries set the same thing…"), not a help beside a control, so it may run the row's width.
        if (row.childElementCount === 1 && help.parentElement === row) continue;
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
        sidebarHeadings: sidebar.querySelectorAll("h1, h2").length,
        sidebarNotices: sidebar.querySelectorAll("[data-doctor-notice]").length,
        ...(() => {
          const box = (element: Element | null) => element!.getBoundingClientRect();
          const middle = (rect: DOMRect) => rect.top + rect.height / 2;
          const center = (rect: DOMRect) => rect.left + rect.width / 2;
          const field = box(sidebar.querySelector(".search-input"));
          const glass = box(sidebar.querySelector(".search .icon"));
          const link = sidebar.querySelector(".section-link[data-section-link]")!;
          const pill = box(link.querySelector(".section-link-content"));
          const icon = box(link.querySelector(".section-icon"));
          const name = link.querySelector<HTMLElement>(".section-name")!;
          const input = sidebar.querySelector<HTMLInputElement>(".search-input")!;
          const textStart = field.left + parseFloat(getComputedStyle(input).paddingLeft);
          return {
            searchOnTitle: Math.round(Math.abs(middle(field) - middle(box(content.querySelector(".section-title"))))),
            searchOnPill: Math.round(Math.abs(field.left - pill.left)),
            glassOnIcon: Math.round(Math.abs(center(glass) - center(icon))),
            textOnName: Math.round(Math.abs(textStart - box(name).left)),
          };
        })(),
        columnWidth: Math.round(columnBox.width),
        leftGap: Math.round(columnBox.left - contentBox.left),
        rightGap: Math.round(contentBox.left + contentInner - columnBox.right),
        wideHelps: helps,
      };
    });

  for (const [name, engine] of engines) {
    describe(name, () => {
      test("Settings is one surface with an untitled, aligned sidebar and a centered 680 px column", async () => {
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
            expect(look.sidebarHeadings).toBe(0);
            expect(look.sidebarNotices).toBe(0);
            expect({ section, searchOnTitle: look.searchOnTitle }).toEqual({ section, searchOnTitle: 0 });
            expect(look.searchOnPill).toBe(0);
            expect(look.glassOnIcon).toBe(0);
            expect(look.textOnName).toBeLessThanOrEqual(1);
            expect(look.columnWidth).toBeLessThanOrEqual(680);
            expect(Math.abs(look.leftGap - look.rightGap)).toBeLessThanOrEqual(2);
            expect(look.wideHelps).toEqual([]);
          }
        } finally {
          await browser.close();
        }
      });

      // Dogfood 2026-11-24: in Menus the editor's title and its four buttons (Expand All, New Submenu,
      // Add Separator, Reset to Default) sat on one unwrapping line wider than the detail column, so
      // Reset to Default ran past the 680 px column and was cut at the window's edge.
      test("Menus keeps its editor's buttons inside the column", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          for (const width of [1100, 1300]) {
            const page = await browser.newPage({ viewport: { width, height: 900 } });
            await installPaintedFrames(page);
            await open(page, "menus");
            const past = await page.evaluate(() => {
              const detail = document.querySelector<HTMLElement>(".menus-detail")!.getBoundingClientRect();
              return [...document.querySelectorAll<HTMLElement>(".menus-detail-header > *")]
                .filter((el) => el.getBoundingClientRect().right > detail.right + 0.5)
                .map((el) => el.textContent?.trim() ?? el.className);
            });
            expect({ width, past }).toEqual({ width, past: [] });
            await page.close();
          }
        } finally {
          await browser.close();
        }
      });
    });
  }
  if (engines.length === 0) describe.skip("settings cohesive look", () => test("engines", () => {}));
});
