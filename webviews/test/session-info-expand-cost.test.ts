// cmux-web-test-timeout: 300
// Opening a Session Info list costs the same at any length (Leo, 2026-11-06: "If I open up this 5,427
// finished, it'll lag. And there's probably more places like that where shit will lag if I open things
// up"). Each expandable list (test/browser/session-info-expand.harness.tsx) at N = 10, 100 and 5000:
// the press's frame draws only the rows the panel can show and a few past them, never all N, and the
// list takes its whole height at once (the rest's room is held). Prints the press-to-paint ms
// (p50 over 5 presses after a warm-up) per list and N: the PR's Performance table.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-expand-cost.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/session-info-expand.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The rows a 700 px window shows at the least row height (24 px), and the overscan of 8.
  const HEIGHT = 700;
  const BOUND = Math.ceil(HEIGHT / 24) + 8;
  const PRESSES = 5;

  test("tasks: the rows past the window draw as the panel scrolls to them", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: HEIGHT } });
    try {
      await page.goto(`http://127.0.0.1:${port}${PAGE}?list=tasks&n=5000`);
      await page.waitForFunction(() => typeof window.__expand === "function");
      await page.evaluate(() => window.__expand());
      // The finished rows open over the settle step (foldMotion.ts); the panel scrolls their whole height
      // once it ends.
      await page.waitForFunction(
        () => !!document.querySelector("ul[data-finished]") && !document.querySelector("[data-folding]"),
      );
      const body = ".acpmux-session-info__body";
      const rows = () => page.locator("ul[data-finished] > li:not([data-rows-rest])").count();
      expect(await rows()).toBeLessThanOrEqual(BOUND);
      // A short scroll draws the next rows, not the rest.
      await page.evaluate((selector) => (document.querySelector(selector)!.scrollTop = 1000), body);
      await page.waitForFunction(
        (bound) => document.querySelectorAll("ul[data-finished] > li:not([data-rows-rest])").length > bound,
        BOUND,
      );
      expect(await rows()).toBeLessThan(200);
      // At the end, the last row is there, in the room held for it.
      const height = await page.evaluate((selector) => document.querySelector(selector)!.scrollHeight, body);
      await page.evaluate((selector) => {
        const scroller = document.querySelector(selector)!;
        scroller.scrollTop = scroller.scrollHeight;
      }, body);
      await page.getByText("bun test shard 4999").waitFor();
      expect(await page.evaluate((selector) => document.querySelector(selector)!.scrollHeight, body)).toBe(height);
    } finally {
      await page.close();
    }
  });

  test("usage: after a sort switch replaces every drawn row, scrolling still draws the rest", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: HEIGHT } });
    try {
      await page.goto(`http://127.0.0.1:${port}${PAGE}?list=usage&n=5000`);
      await page.waitForFunction(() => typeof window.__expand === "function");
      await page.evaluate(() => window.__expand());
      const drawn = () =>
        page.evaluate(() => document.querySelectorAll("ul[data-sort] > li:not([data-rows-rest])").length);
      expect(await drawn()).toBeLessThanOrEqual(BOUND);
      // Context's order is the reverse of cost's: none of the rows drawn before stays mounted.
      await page.locator(".acpmux-session-info-usage__sort-option:not([disabled])").click();
      await page.waitForFunction(
        () => document.querySelector("ul[data-sort]")?.getAttribute("data-sort") === "context",
      );
      expect(await drawn()).toBeLessThanOrEqual(BOUND);
      await page.evaluate(() => (document.querySelector(".acpmux-session-info__body")!.scrollTop = 1000));
      await page.waitForFunction(
        (bound) => document.querySelectorAll("ul[data-sort] > li:not([data-rows-rest])").length > bound,
        BOUND,
      );
    } finally {
      await page.close();
    }
  });

  test("usage: Tab and Shift-Tab reach every row, not only the drawn window", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: HEIGHT } });
    try {
      await page.goto(`http://127.0.0.1:${port}${PAGE}?list=usage&n=5000`);
      await page.waitForFunction(() => typeof window.__expand === "function");
      await page.evaluate(() => window.__expand());
      /// The focused row's place in the list, or -1 when focus is outside it.
      const focusedRow = () =>
        page.evaluate(() => {
          const row = document.activeElement?.closest("ul[data-sort] > li");
          return row ? [...row.parentElement!.children].indexOf(row) : -1;
        });
      await page.locator("ul[data-sort] > li button").first().focus();
      for (let press = 0; press < 60; press += 1) await page.keyboard.press("Tab");
      expect(await focusedRow()).toBe(60);
      // From the fold under the list, Shift-Tab lands on the list's true last row.
      await page.locator(".acpmux-session-info-usage-fold").focus();
      await page.keyboard.press("Shift+Tab");
      await page.waitForFunction(
        () => document.activeElement?.querySelector(".acpmux-session-info-row__name")?.textContent === "Chat 0",
      );
    } finally {
      await page.close();
    }
  });

  for (const list of ["tasks", "subagents", "outputs", "sources", "changes", "usage", "alsoHere"]) {
    test(`${list}: opening the list draws only the rows that can show, at any length`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: HEIGHT } });
      const report: Record<number, { p50: number; rows: number; height: number }> = {};
      try {
        for (const n of [10, 100, 5000]) {
          await page.goto(`http://127.0.0.1:${port}${PAGE}?list=${list}&n=${n}`);
          await page.waitForFunction(() => typeof window.__expand === "function");
          const times: number[] = [];
          let opened = { ms: 0, rows: 0, listHeight: 0 };
          // One warm-up, then PRESSES opens; each open is closed again before the next.
          for (let press = 0; press <= PRESSES; press += 1) {
            opened = await page.evaluate(() => window.__expand());
            if (press > 0) times.push(opened.ms);
            await page.evaluate(() => window.__expand());
          }
          times.sort((a, b) => a - b);
          report[n] = {
            p50: Math.round(times[Math.floor(times.length / 2)]! * 10) / 10,
            rows: opened.rows,
            height: opened.listHeight,
          };
        }
      } finally {
        console.log(`SESSION-INFO-EXPAND ${list} ${JSON.stringify(report)}`);
        await page.close();
      }
      for (const n of [10, 100, 5000])
        expect(report[n]!.rows, `${list} at ${n}: rows drawn in the press's frame`).toBeLessThanOrEqual(BOUND);
      // The rest's room is held: the list is about as tall as all its rows.
      expect(report[5000]!.height, `${list} at 5000: the list's height`).toBeGreaterThan(5000 * 20);
    });
  }
});
