// l10n-allow-file: gallery fixture names are test data.
// The composer hat's header icons never move when the hat opens or folds (Leo, 2026-11-14, on the
// open hat's split-pane button and chevron sitting left of where they sat folded: "the alignment
// changes in the expanded mode for some reason. don't do that for the composer hat"). The open list
// of more than five lines scrolls, and under macOS's "Always" scroll bars (WebKit's legacy scroller,
// which the pane draws thin: scrollers.ts SCROLLER_ROOT_CSS) its scrollbar took 8px of the lines'
// width. The header used to move its panel button and chevron in by that width to stay over the
// lines' columns, so they jumped on every toggle. Now the header stays put, and the lines give the
// scrollbar their own end inset, so their Stop squares and chevrons stay under the header's.
//
// Real Chromium (Playwright), the gallery's `agent-pane.subagent-tray-open`: the panel button's and
// the chevron's rects, folded and open, at 760 and 360px, with three lines (no scrollbar) and eight
// (a scrolling list), under the thin legacy scroller and Chromium's own classic one.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { SCROLLER_ROOT_CSS } from "../src/scrollers";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { openRunningTray } from "./support/openRunningTray";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { RUNNING_TRAY_LIST_LINE } from "../src/agent-session/acpmux/subagents/subagentSelectors";

await requireBrowserLane("composer-hat-head-still.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.subagent-tray-open";
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    // Scrollbars drawn: Playwright hides them in headless Chromium by default.
    browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "many-folded" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  type Rect = { left: number; right: number; top: number; bottom: number };

  /** The header's icons, relative to the hat's top-right corner (the hat grows upward as it opens). */
  const measure = (page: Page) =>
    page.evaluate(
      ({ RUNNING_TRAY_LIST_LINE }) => {
        const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
        const edge = tray.getBoundingClientRect();
        const rel = (node: Element | null): Rect | null => {
          if (!node) return null;
          const rect = node.getBoundingClientRect();
          return {
            left: rect.left - edge.right,
            right: rect.right - edge.right,
            top: rect.top - edge.top,
            bottom: rect.bottom - edge.top,
          };
        };
        const head = tray.querySelector(".acpmux-running-tray__head")!;
        const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list");
        return {
          trayRight: edge.right,
          head: rel(head)!,
          panel: rel(tray.querySelector(".acpmux-running-tray__open > svg"))!,
          chevron: rel(tray.querySelector(".acpmux-running-tray__chevron > svg"))!,
          gutter: list ? list.offsetWidth - list.clientWidth : 0,
          lines: [...tray.querySelectorAll(RUNNING_TRAY_LIST_LINE)].map((line) => ({
            stop: rel(line.querySelector(".acpmux-agent-line__stop-track")),
            chevron: rel(line.querySelector(".acpmux-agent-line__chevron > svg")),
          })),
        };
      },
      { RUNNING_TRAY_LIST_LINE },
    );

  const center = (rect: Rect) => (rect.left + rect.right) / 2;

  const scrollers = { legacy: true, classic: false } as const;

  for (const [scroller, legacy] of Object.entries(scrollers))
    for (const width of [760, 360])
      for (const variant of ["many-folded", "folded"]) {
        test(`${variant} at ${width}px, ${scroller} scroller: the header's icons sit where they sat folded`, async () => {
          const port = (server.httpServer!.address() as { port: number }).port;
          const page = await browser.newPage({ viewport: { width, height: 640 }, deviceScaleFactor: 2 });
          try {
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            if (legacy) {
              // The host's "Always" scroll bars (WebTheme.swift sets the attribute; the pane draws the
              // thin themed scroller, scrollers.ts).
              await page.addStyleTag({ content: SCROLLER_ROOT_CSS });
              await page.evaluate(() => document.documentElement.setAttribute("data-scrollers", "legacy"));
            }
            await page.waitForSelector(".acpmux-running-tray__open");
            const folded = await measure(page);
            expect(folded.lines.length).toBe(0);
            // The tuck control shows with the pointer on the hat. Its click box (96 by 12px at the top
            // middle; it was 8px tall) stops above the header's centre line, so the real click on the
            // header's middle below still opens the hat, never tucks it (Leo, 2026-11-14: "the tuck
            // away chevron clickability/visuals should be improved somehow").
            await page.locator(".acpmux-running-tray__title").hover();
            await page.waitForFunction(
              () => getComputedStyle(document.querySelector(".acpmux-running-tray__tuck")!).opacity === "1",
            );
            const tuck = await page.evaluate(() => {
              const tray = document.querySelector(".acpmux-running-tray")!.getBoundingClientRect();
              const box = document.querySelector(".acpmux-running-tray__tuck")!.getBoundingClientRect();
              return {
                width: box.width,
                top: box.top - tray.top,
                height: box.height,
                center: box.left + box.width / 2 - (tray.left + tray.width / 2),
              };
            });
            expect(tuck.width).toBeGreaterThanOrEqual(96);
            expect(tuck.height).toBeGreaterThanOrEqual(12);
            expect(tuck.top).toBe(0);
            expect(tuck.top + tuck.height).toBeLessThan(14);
            expect(Math.abs(tuck.center)).toBeLessThanOrEqual(0.5);
            await openRunningTray(page);
            const open = await measure(page);
            const report = JSON.stringify({ folded, open: { ...open, lines: open.lines.length } });
            expect(open.lines.length, report).toBeGreaterThan(0);
            if (variant === "many-folded") {
              // The case Leo saw: more lines than the list holds, so it scrolls and takes a scrollbar.
              expect(open.lines.length, report).toBeGreaterThan(5);
              expect(open.gutter, report).toBeGreaterThan(0);
            } else expect(open.gutter, report).toBe(0);
            // The hat itself stays on the composer's column.
            expect(Math.abs(open.trayRight - folded.trayRight), report).toBeLessThanOrEqual(0.5);
            expect(
              Math.abs(open.head.bottom - open.head.top - (folded.head.bottom - folded.head.top)),
              report,
            ).toBeLessThanOrEqual(0.5);
            for (const part of ["panel", "chevron"] as const)
              for (const side of ["left", "right", "top", "bottom"] as const)
                expect(
                  Math.abs(open[part][side] - folded[part][side]),
                  `${part} ${side}: folded ${folded[part][side]} open ${open[part][side]} ${report}`,
                ).toBeLessThanOrEqual(0.5);
            // The lines' Stop squares and chevrons stay under the header's panel button and chevron:
            // the scrollbar takes the lines' end inset, never their columns. Chromium's own classic
            // scrollbar (15px) is wider than the inset, which the app never draws (it draws the thin
            // one), so only the header is held to its place there.
            if (legacy)
              for (const line of open.lines) {
                if (line.stop)
                  expect(Math.abs(center(line.stop) - center(open.panel)), report).toBeLessThanOrEqual(0.5);
                if (line.chevron)
                  expect(Math.abs(center(line.chevron) - center(open.chevron)), report).toBeLessThanOrEqual(0.5);
              }
          } finally {
            await page.close();
          }
        });
      }
});
