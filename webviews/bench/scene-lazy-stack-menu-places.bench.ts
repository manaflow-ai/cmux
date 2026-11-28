// l10n-allow-file: benchmark output, not shipped UI.
// Rows keep their places while a context menu is open in a LazyVStack's styled Group, on Chromium and WebKit,
// a production build of test/browser/scene-lazy-stack-visible-only.html (`#groups=1&menus=1`, N Rows in a
// scroller the page owns). With the stack scrolled into the middle, the page right-clicks a grouped Row in
// view and narrows the window to 700 px and back (under the page body's 720 px column, so the stack's box
// resizes and its mounted Groups are measured again with the menu open), closes the menu, moves focus off the
// Row (the stack keeps a focused child mounted) and scrolls 2,000 px down, so that Group unmounts and a spacer
// holds its measured place; the same steps with no menu are the reference. Per browser:
//   anchor      whether the open menu's anchor is in the Group;
//   maxShift    the largest move of a mounted Row's offset in the scroller's content, menu open vs not;
//   height      the change in the scroller's content height, menu open vs not.
//   bun bench/scene-lazy-stack-menu-places.bench.ts [n]   (default 1000)
/// <reference types="bun" />
import type { Browser, BrowserType, Page } from "playwright";
import { chromium, webkit } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

declare global {
  interface Window {
    benchReady: boolean;
  }
}

const N = Number(benchPositionals()[0] ?? 1_000);
const served = await serveBenchPage("/test/browser/scene-lazy-stack-visible-only.html");
const paint = (page: Page, frames = 2) =>
  page.evaluate(async (count) => {
    for (let frame = 0; frame < count; frame++) await window.cmuxPaintFrame();
  }, frames);

/** Each mounted Row's offset in the scroller's content, and the content's height. */
const places = (page: Page) =>
  page.evaluate(() => {
    const scroller = document.querySelector<HTMLElement>(".nt-app-page")!;
    const top = scroller.getBoundingClientRect().top - scroller.scrollTop;
    const rows: Record<string, number> = {};
    for (const row of document.querySelectorAll<HTMLElement>("[data-app-type=Row]"))
      rows[row.dataset.appNode!] = row.getBoundingClientRect().top - top;
    return { rows, height: scroller.scrollHeight };
  });

/** Narrows the window under the page body's 720 px column for two frames, and widens it back. */
async function wiggle(page: Page) {
  await page.evaluate(() => (document.getElementById("root")!.style.width = "700px"));
  await paint(page);
  await page.evaluate(() => (document.getElementById("root")!.style.width = "900px"));
  await paint(page, 3);
}

async function run(browser: Browser, open: boolean) {
  const context = await browser.newContext({ viewport: { width: 900, height: 800 } });
  const page = await context.newPage();
  await installPaintedFrames(page);
  await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}&groups=1&menus=1` });
  await requireProductionReact(page, { dev: served.dev });
  await page.waitForFunction(() => window.benchReady === true);
  await page.evaluate(() => {
    const scroller = document.querySelector<HTMLElement>(".nt-app-page")!;
    scroller.scrollTop = scroller.scrollHeight / 2;
  });
  await paint(page, 3);
  let anchor = false;
  if (open) {
    // The first grouped Row fully in view.
    const box = await page.evaluate(() => {
      for (const row of document.querySelectorAll<HTMLElement>("[data-app-type=Group] [data-app-type=Row]")) {
        const rect = row.getBoundingClientRect();
        if (rect.top >= 0 && rect.bottom <= innerHeight) return { x: rect.left + 20, y: rect.top + rect.height / 2 };
      }
      throw new Error("no grouped row in view");
    });
    await page.mouse.click(box.x, box.y, { button: "right" });
    await paint(page);
    anchor = await page.evaluate(
      () => document.querySelector("[data-app-type=Group] .cmux-app-scene-context-anchor") !== null,
    );
  }
  await wiggle(page);
  if (open) {
    // The menu gives focus back to the Row once it closes, so focus moves off after that.
    await page.keyboard.press("Escape");
    await paint(page);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await paint(page);
    if (await page.evaluate(() => document.activeElement?.closest("[data-app-type=Row]") != null))
      throw new Error("focus is still on a Row");
  }
  await page.evaluate(() => (document.querySelector<HTMLElement>(".nt-app-page")!.scrollTop += 2_000));
  await paint(page, 3);
  const result = await places(page);
  await context.close();
  return { ...result, anchor };
}

const engines: Array<[string, BrowserType]> = [
  ["chromium", chromium],
  ["webkit", webkit],
];
try {
  for (const [name, type] of engines) {
    const browser = await type.launch({ headless: true });
    try {
      const closed = await run(browser, false);
      const opened = await run(browser, true);
      let maxShift = 0;
      let compared = 0;
      for (const [id, top] of Object.entries(opened.rows)) {
        const reference = closed.rows[id];
        if (reference === undefined) continue;
        compared++;
        maxShift = Math.max(maxShift, Math.abs(top - reference));
      }
      console.log(
        `scene-lazy-stack-menu-places n=${N} browser=${name} build=${served.dev ? "dev" : "production"} ` +
          `anchor=${opened.anchor} rows=${compared} maxShift=${maxShift.toFixed(1)}px ` +
          `height=${(opened.height - closed.height).toFixed(1)}px`,
      );
    } finally {
      await browser.close();
    }
  }
} finally {
  await served.close();
}
