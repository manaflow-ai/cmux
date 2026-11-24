// l10n-allow-file: test fixtures, not shipped UI.
// SPINNERS-OFF-MAIN perf check: what 1 and 20 running "Thinking" lines cost the page's main thread
// while they shimmer, in Chromium (CDP Performance metrics over a 2 s window). The old shimmer (a
// text-clipped gradient's `background-position`, kept below as the fixture it was) restyles and
// repaints the words every frame; the compositor shimmer (ShimmerText.tsx) restyles nothing per
// frame once its loops start. Prints the table (main-thread task ms/s, style recalcs/s) and fails
// when the current lines restyle per frame.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("working-loops-main-thread.test.tsx", async () => {
  setDefaultTimeout(90_000);
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  const line = renderToStaticMarkup(<Thinking since={START} now={() => START + 18_000} below />);
  // The shimmer as it was before SPINNERS-OFF-MAIN (conversation.css, feat-cmux-next f8c77f41717).
  const oldCss = `@keyframes old-shimmer { from { background-position: 100% 0 } to { background-position: -50% 0 } }
    .old-line { display: inline-block; color: transparent; white-space: nowrap;
      background: linear-gradient(100deg, #6e6e78 35%, #e6e6e6 50%, #6e6e78 65%) 0 0 / 250% 100%;
      -webkit-background-clip: text; background-clip: text; -webkit-text-fill-color: transparent;
      animation: old-shimmer 2.4s linear infinite; }`;
  const oldLine = `<div><output class="old-line">Thinking</output></div>`;
  const WINDOW_MS = 2000;

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true }).catch(() => undefined);
  });
  afterAll(async () => {
    await browser?.close();
  });

  /** Main-thread task ms per second and style recalcs per second with `count` lines shimmering. */
  async function cost(styles: string, markup: string, count: number) {
    const page = await browser!.newPage();
    try {
      await page.setContent(
        `<html style="--agent-text: rgb(230,230,230); --agent-muted: rgb(160,160,170)">` +
          `<head><style>${styles}</style></head><body>${markup.repeat(count)}</body></html>`,
      );
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Performance.enable");
      // Let the loops start (their first frames restyle once), then measure a steady window.
      // fixed-wait: a measurement settles its loops before the window; no signal says "steady".
      await page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 300)));
      const metric = async () => {
        const { metrics } = await cdp.send("Performance.getMetrics");
        const get = (name: string) => metrics.find((entry) => entry.name === name)?.value ?? 0;
        return { task: get("TaskDuration"), recalcs: get("RecalcStyleCount") };
      };
      const before = await metric();
      const began = Date.now();
      // fixed-wait: the measured window itself.
      await page.evaluate((ms) => new Promise((resolve) => setTimeout(resolve, ms)), WINDOW_MS);
      const after = await metric();
      const seconds = (Date.now() - began) / 1000;
      return {
        taskMsPerS: Math.round(((after.task - before.task) * 1000 * 10) / seconds) / 10,
        recalcsPerS: Math.round((after.recalcs - before.recalcs) / seconds),
      };
    } finally {
      await page.close();
    }
  }

  describe("running Thinking lines cost the page's main thread nothing per frame (chromium)", () => {
    test("1 and 20 lines, before and after", async () => {
      if (!browser) return console.warn("working-loops-main-thread: chromium did not launch");
      const rows: { shimmer: string; count: number; taskMsPerS: number; recalcsPerS: number }[] = [];
      for (const count of [1, 20]) {
        // fixed-wait: each cost() call is a timed measurement window.
        rows.push({ shimmer: "before (background-position)", count, ...(await cost(oldCss, oldLine, count)) });
        // fixed-wait: each cost() call is a timed measurement window.
        rows.push({ shimmer: "after (compositor)", count, ...(await cost(css, line, count)) });
      }
      const table =
        "SPINNERS-MAIN-THREAD\n" +
        rows
          .map((row) => `${row.shimmer}\t${row.count}\t${row.taskMsPerS} ms/s\t${row.recalcsPerS} recalcs/s`)
          .join("\n");
      console.log(table);
      // The table for the fleet step's artifact (a passing file's output is not printed).
      mkdirSync(path.resolve(import.meta.dir, "../../artifacts"), { recursive: true });
      writeFileSync(path.resolve(import.meta.dir, "../../artifacts/spinners-main-thread.txt"), table + "\n");
      // The measurement sees per-frame work: the old shimmer restyles every frame.
      const old20 = rows.find((row) => row.count === 20 && row.shimmer.startsWith("before"))!;
      expect(old20.recalcsPerS).toBeGreaterThan(20);
      // The compositor shimmer restyles nothing per frame, at 1 line or 20.
      for (const row of rows.filter((entry) => entry.shimmer.startsWith("after")))
        expect({ count: row.count, recalcsPerS: row.recalcsPerS }).toEqual({ count: row.count, recalcsPerS: 0 });
    });
  });
});
