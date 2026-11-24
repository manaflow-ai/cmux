// cmux-web-test-timeout: 600
// A deep link to a windowed Settings card (cardWindow.ts) opens the page on that card: the
// Customization Library (`#/settings/personalization?focus=card.customizeLibrary`, the trail card,
// 5,000 px down the page) and Shared Links (`#/settings/privacy?focus=card.sharedLinks`, the lead card).
// Review of #46364, F1: the card scrolled itself into view in its first commit, and the next commit's
// window took the page's scroller over and wrote back the offset it had read before (0), so the
// page opened at the top of Personalization. The card now reveals itself once its window is ready
// (`ready`), and the window starts at the scroller's own offset.
//
// A production build of test/browser/settings-cards-visible-only.html (the real page over the mock
// host) with 600 entries or links, in Chromium and WebKit; the page is read once it has painted 20
// frames in a row with the same scroll and card place.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/settings-card-reveal-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("settings-card-reveal-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines = [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const;
  const runs: (readonly [string, typeof chromium])[] = [];
  for (const [name, engine] of engines)
    if (await probeEngineOrSkip(`settings-card-reveal-browser ${name}`, name, engine)) runs.push([name, engine]);
  let served: BenchPage;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    // `bun test` runs with NODE_ENV=test, and Vite's JSX transform follows it: the build would call
    // the development JSX runtime that production React does not have. The page is built as a user
    // runs it.
    const nodeEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/settings-cards-visible-only.html");
    } finally {
      process.env.NODE_ENV = nodeEnv;
    }
    for (const [name, engine] of runs) browsers.set(name, await engine.launch({ headless: true }));
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await served?.close();
  });

  const cards = [
    { card: "library", name: "customizeLibrary" },
    { card: "shares", name: "sharedLinks" },
  ] as const;
  for (const [engine] of runs) {
    for (const { card, name } of cards) {
      test(`${engine}: the deep link to ${name} with 600 rows opens the page on the card`, async () => {
        const page = await browsers.get(engine)!.newPage({ viewport: { width: 1200, height: 800 } });
        try {
          await installPaintedFrames(page);
          await gotoBenchPage(page, { ...served, url: `${served.url}#card=${card}&n=600&reveal=1` });
          await requireProductionReact(page, { dev: served.dev });
          await page.waitForFunction(
            (name) =>
              (window as { benchReady?: boolean }).benchReady === true &&
              !!document.querySelector(`[data-card="${name}"] [data-index]`),
            name,
          );
          const settled = await page.evaluate(
            (name) =>
              new Promise<{ scrollTop: number; viewTop: number; viewBottom: number; cardTop: number; rows: number }>(
                (resolve) => {
                  let last = "";
                  let same = 0;
                  window.cmuxAfterPaint(() => {
                    const scroller = document.querySelector<HTMLElement>("main.content")!;
                    const cardElement = document.querySelector<HTMLElement>(`[data-card="${name}"]`)!;
                    const view = scroller.getBoundingClientRect();
                    const top = cardElement.getBoundingClientRect().top;
                    const place = `${scroller.scrollTop}|${top}`;
                    same = place === last ? same + 1 : 0;
                    last = place;
                    if (same < 20) return true;
                    resolve({
                      scrollTop: scroller.scrollTop,
                      viewTop: view.top,
                      viewBottom: view.bottom,
                      cardTop: top,
                      rows: cardElement.querySelectorAll("[data-index]").length,
                    });
                    return false;
                  });
                },
              ),
            name,
          );
          // The card's top is in the scroller's viewport, in its top fifth (under the jump bar's
          // scroll margin), and the window has rows mounted there.
          expect(settled.cardTop).toBeGreaterThanOrEqual(settled.viewTop);
          expect(settled.cardTop).toBeLessThan(settled.viewTop + (settled.viewBottom - settled.viewTop) / 5);
          expect(settled.rows).toBeGreaterThan(0);
        } finally {
          await page.close();
        }
      });
    }
  }
});
