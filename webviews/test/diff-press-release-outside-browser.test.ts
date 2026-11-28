// A press on a Feed or Artifacts diff line keeps that line mounted until it is released
// (pages/feed/DiffLines.tsx, pages/artifacts/DiffLines.tsx, through watchPress in ui/pressRelease.ts).
// DiffLines takes no pointer capture and a mouse gets none implicitly, so a button let go outside the
// focused window can reach the page as nothing at all: no pointerup, no lostpointercapture. The page
// hears the release only as the next move, with no button down. This presses a real line, drags out
// of the page and back with no release event, and checks that the line unmounts once scrolled away.
//
// Chromium only: the press, the drag out and the move back with no button go through the DevTools
// protocol (Input.dispatchMouseEvent: mousePressed, mouseMoved with buttons 1 to outside the
// viewport, mouseMoved with buttons 0 back over the page, never mouseReleased), which is the input
// Chromium gets when the release happens over another window. The page counts every pointerup,
// pointercancel, lostpointercapture and window blur it hears, and the test requires none. WebKit
// has no such protocol, and Playwright's mouse never moves without the buttons it holds.
//
// A production build of test/browser/feed-visible-only.html and artifacts-visible-only.html, as
// their benches serve them.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/diff-press-release-outside-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("diff-press-release-outside-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("diff-press-release-outside-browser chromium", "chromium", chromium))) return;
  setDefaultTimeout(300_000);

  const N = 10_000;
  const pages = [
    {
      name: "Feed",
      path: "/test/browser/feed-visible-only.html",
      line: ".feed-detail .feed-diff-line",
      scroller: ".feed-detail-scroll",
    },
    {
      name: "Artifacts",
      path: "/test/browser/artifacts-visible-only.html",
      line: ".artifacts-line",
      scroller: ".artifacts-history",
    },
  ] as const;
  const served = new Map<string, BenchPage>();
  beforeAll(async () => {
    // bun test sets NODE_ENV=test, and Vite would build React's development JSX into the page.
    const env = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      for (const { name, path } of pages) served.set(name, await serveBenchPage(path, { dev: false }));
    } finally {
      process.env.NODE_ENV = env;
    }
  });
  afterAll(async () => {
    for (const page of served.values()) await page.close();
  });

  const settle = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );

  for (const { name, line, scroller } of pages)
    test(`chromium: ${name}: a press released outside the window, heard only as a move with no button, unmounts its line once scrolled away`, async () => {
      const browser = await chromium.launch({ headless: true });
      try {
        const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
        const page = await context.newPage();
        const bench = served.get(name)!;
        await gotoBenchPage(page, { ...bench, url: `${bench.url}#n=${N}` });
        await requireProductionReact(page, { dev: bench.dev });
        await page.waitForFunction((line) => window.benchReady === true && !!document.querySelector(line), line);
        const scrollTo = async (index: number) => {
          await page.evaluate(
            ({ scroller, line, index }) => {
              const pane = document.querySelector<HTMLElement>(scroller)!;
              const first = document.querySelector<HTMLElement>(line)!;
              const top = first.getBoundingClientRect().top - pane.getBoundingClientRect().top + pane.scrollTop;
              pane.scrollTop = Math.max(
                0,
                top - Number(first.dataset.index) * first.offsetHeight + (index - 2) * first.offsetHeight,
              );
            },
            { scroller, line, index },
          );
          await page.waitForFunction(({ line, index }) => !!document.querySelector(`${line}[data-index="${index}"]`), {
            line,
            index,
          });
          await settle(page);
        };
        const mounted = (index: number) =>
          page.evaluate(({ line, index }) => !!document.querySelector(`${line}[data-index="${index}"]`), {
            line,
            index,
          });
        // Every release the page could hear, counted from here on.
        await page.evaluate(() => {
          const heard: Record<string, number> = {};
          (window as unknown as { heard: Record<string, number> }).heard = heard;
          for (const type of ["pointerup", "pointercancel", "lostpointercapture", "mouseup"])
            window.addEventListener(type, () => (heard[type] = (heard[type] ?? 0) + 1), true);
          window.addEventListener("blur", (event) => {
            if (event.target === window) heard.blur = (heard.blur ?? 0) + 1;
          });
        });

        const PRESSED = 100;
        await scrollTo(PRESSED);
        const box = (await page.locator(`${line}[data-index="${PRESSED}"]`).boundingBox())!;
        const x = Math.round(box.x + 20);
        const y = Math.round(box.y + box.height / 2);
        const cdp = await context.newCDPSession(page);
        const mouse = (params: Record<string, unknown>) => cdp.send("Input.dispatchMouseEvent", params as never);
        await mouse({ type: "mouseMoved", x, y, button: "none", buttons: 0 });
        await mouse({ type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1 });
        await mouse({ type: "mouseMoved", x: x + 30, y, button: "left", buttons: 1 });
        // Out of the page (over another window), where the button comes up unheard.
        await mouse({ type: "mouseMoved", x: 1_250, y: 850, button: "left", buttons: 1 });
        // The press put a caret on its line (a selection end, which keeps its line mounted on its
        // own); without it only the press holds the line.
        await page.evaluate(() => document.getSelection()!.removeAllRanges());
        await settle(page);

        // Still held: the line stays mounted far away.
        await scrollTo(9_000);
        expect(await mounted(PRESSED)).toBe(true);

        // Back over the page with no button down: the only sign of the release.
        await mouse({ type: "mouseMoved", x: 600, y: 400, button: "none", buttons: 0 });
        await settle(page);
        const heard = await page.evaluate(() => (window as unknown as { heard: Record<string, number> }).heard);
        console.log(JSON.stringify({ page: name, heard }));
        expect(heard).toEqual({});

        await scrollTo(9_400);
        expect(await mounted(PRESSED)).toBe(false);
      } finally {
        await browser.close();
      }
    });
});
