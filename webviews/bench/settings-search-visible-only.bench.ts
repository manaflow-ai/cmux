// l10n-allow-file: benchmark output, not shipped UI.
// Settings search on Chromium, a production build (React Compiler, minified) of
// test/browser/settings-cards-visible-only.html (`card=search`): the real page over the in-memory
// mock host. Search keeps a collapsing slot per setting mounted (the schema's size, not the
// person's data), so the numbers are per keystroke:
//   slots, nodes   result slots mounted and DOM nodes under the results;
//   open           slots open before and after the keystroke ("fon" -> "font");
//   drawnPerKey    slots drawn again by that keystroke (the open ones redraw: their highlight follows
//                  the query);
//   keyP95         ms in the page from a keystroke's input event to the task after the frame that
//                  shows it painted (p95 of KEYS).
//   bun bench/settings-search-visible-only.bench.ts
/// <reference types="bun" />
import { chromium } from "./browsers";
import { gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowSelector: string;
    benchRowRenders: { mark(): void; since(): number };
  }
}

const KEYS = 20;
const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/settings-cards-visible-only.html");
try {
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  const page = await context.newPage();
  await installPaintedFrames(page);
  await gotoBenchPage(page, { ...served, url: `${served.url}#card=search` });
  await requireProductionReact(page, { dev: served.dev });
  await page.waitForFunction(() => window.benchReady === true && !!document.querySelector("[data-settings-search]"));
  const field = page.locator("[data-settings-search]");
  await field.fill("fon");
  await page.waitForFunction(() => document.querySelectorAll(window.benchRowSelector).length > 0);
  await page.evaluate(() => window.cmuxPaintFrame());
  const mounted = await page.evaluate(() => {
    const results = document.querySelector("[data-search-results]")!;
    return {
      slots: results.querySelectorAll(window.benchRowSelector).length,
      nodes: results.querySelectorAll("*").length,
    };
  });

  // One keystroke ("fon" -> "font"): the slots drawn again.
  const keystroke = await page.evaluate(() => {
    window.benchRowRenders.mark();
    return { before: document.querySelectorAll(`${window.benchRowSelector}[data-open]`).length };
  });
  await field.press("t");
  await page.evaluate(() => window.cmuxPaintFrame());
  await page.evaluate(() => window.cmuxPaintFrame());
  const drawn = await page.evaluate(() => window.benchRowRenders.since());
  const open = await page.evaluate(() => document.querySelectorAll(`${window.benchRowSelector}[data-open]`).length);

  // Keystroke frames, timed in the page: from the input event (a letter typed, then erased) to the
  // task after the frame that shows it painted.
  const frames: number[] = [];
  for (let index = 0; index < KEYS; index++) {
    frames.push(
      await page.evaluate(
        async (typed) => {
          const input = document.querySelector<HTMLInputElement>("[data-settings-search]")!;
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
          const started = performance.now();
          setter.call(input, typed ? "fonts" : "font");
          input.dispatchEvent(new Event("input", { bubbles: true }));
          await window.cmuxPaintFrame();
          return performance.now() - started;
        },
        index % 2 === 0,
      ),
    );
  }
  await context.close();
  console.log(
    `settings-search-visible-only build=${served.dev ? "dev" : "production"} slots=${mounted.slots} nodes=${mounted.nodes} ` +
      `open=${keystroke.before}->${open} drawnPerKey=${drawn} keyP95=${pct(frames, 0.95).toFixed(1)}ms`,
  );
} finally {
  await browser.close();
  await served.close();
}
