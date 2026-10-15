// cmux-web-test-timeout: 240
// The Settings page scrolls in one place (cx-jh7kq), in real engines (headless Chromium and WebKit
// from Playwright) on the settings dev server with the in-memory mock (`?mock`):
// - the content column is the page's only scroller: the document never scrolls, also while a
//   select's pop-up is open and the wheel keeps going past the end;
// - every row is rendered once and stays: scrolling top to bottom removes no row and moves none;
// - an open pop-up stays on screen at its anchor while the content scrolls under it;
// - opening a font or theme list pushes no row down;
// - the content's edges fade instead of clipping a row hard.
//
// The engines come from `playwright install chromium webkit`. Where one is not installed, its
// cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { stopDevServer } from "./support/devServer";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("settings-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
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
      console.warn(`settings-scroll: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  let server: ChildProcess | null = null;
  let base = "";

  beforeAll(async () => {
    if (engines.length === 0) return;
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(
      path.join(webviews, "node_modules/.bin/vp"),
      ["dev", "--config", "vite.config.settings-page.mjs", "--port", String(port), "--strictPort"],
      { cwd: webviews, stdio: ["ignore", "ignore", "ignore"] },
    );
    base = `http://127.0.0.1:${port}`;
    const deadline = Date.now() + 60_000;
    let listening = false;
    while (!listening && Date.now() < deadline) {
      try {
        listening = (await fetch(`${base}/`)).ok;
      } catch {
        // Not listening yet.
      }
      if (!listening) await new Promise((resolve) => setTimeout(resolve, 250));
    }
    if (!listening) throw new Error("settings dev server did not start");
    await warmDevServer(base, "/");
  }, 180_000);

  afterAll(() => {
    stopDevServer(server);
  });

  /** The page's scroll state: the document's, and every element that scrolls a row. */
  const scrollState = (page: Page) =>
    page.evaluate(() => {
      const doc = document.scrollingElement!;
      const scrollers = new Set<Element>();
      for (const row of document.querySelectorAll("[data-row-key]")) {
        for (let node = row.parentElement; node && node !== document.body; node = node.parentElement) {
          const overflow = getComputedStyle(node).overflowY;
          if ((overflow === "auto" || overflow === "scroll") && node.scrollHeight > node.clientHeight)
            scrollers.add(node);
        }
      }
      const content = document.querySelector(".content")!;
      return {
        documentScrolls: doc.scrollHeight > doc.clientHeight || doc.scrollTop !== 0,
        documentHeight: doc.scrollHeight,
        scrollers: [...scrollers].map((node) => node.className),
        contentTop: content.scrollTop,
        contentEnd: content.scrollHeight - content.clientHeight,
      };
    });

  /** Remembers the rendered rows and their offsets, and counts any row the page removes later. */
  const watchRows = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as { rows: Element[]; tops: number[]; removed: number };
      state.rows = [...document.querySelectorAll("[data-row-key]")];
      state.tops = state.rows.map((row) => (row as HTMLElement).offsetTop);
      state.removed = 0;
      new MutationObserver((records) => {
        for (const record of records)
          for (const node of record.removedNodes)
            if (node instanceof Element && (node.matches("[data-row-key]") || node.querySelector("[data-row-key]")))
              state.removed += 1;
      }).observe(document.body, { subtree: true, childList: true });
      return state.rows.length;
    });

  const rowsSince = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as { rows: Element[]; tops: number[]; removed: number };
      const now = [...document.querySelectorAll("[data-row-key]")];
      return {
        removed: state.removed,
        replaced: now.length !== state.rows.length || now.some((row, k) => row !== state.rows[k]),
        moved: state.rows
          .filter((row, k) => (row as HTMLElement).offsetTop !== state.tops[k])
          .map((row) => row.getAttribute("data-row-key")),
      };
    });

  const open = async (page: Page, section: string) => {
    await page.goto(`${base}/?mock#/settings/${section}`);
    await page.waitForSelector(".content [data-row-key]");
    // The mock answers at once; a frame more for the cards that render from its answers.
    await page.waitForTimeout(500);
    await page.mouse.move(640, 350);
  };

  for (const [name, engine] of engines) {
    describe(name, () => {
      let browser: Browser;
      let page: Page;

      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
        page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
      });

      afterAll(async () => {
        await browser?.close();
      });

      test("scrolling Appearance top to bottom: one scroller, no row removed or moved", async () => {
        await open(page, "appearance");
        expect(await watchRows(page)).toBeGreaterThan(40);
        const steps: string[] = [];
        for (let step = 0; step < 80; step += 1) {
          const state = await scrollState(page);
          if (state.documentScrolls || state.scrollers.length !== 1) steps.push(`${step}: ${JSON.stringify(state)}`);
          if (state.contentTop >= state.contentEnd && step > 0) {
            // Past the end the wheel goes nowhere: never on to the document.
            for (let extra = 0; extra < 5; extra += 1) await page.mouse.wheel(0, 240);
            await page.waitForTimeout(100);
            const after = await scrollState(page);
            if (after.documentScrolls) steps.push(`past the end: ${JSON.stringify(after)}`);
            break;
          }
          await page.mouse.wheel(0, 120);
          await page.waitForTimeout(16);
        }
        const end = await scrollState(page);
        expect(steps).toEqual([]);
        expect(end.scrollers).toEqual(["content"]);
        expect(end.contentTop).toBe(end.contentEnd);
        expect(await rowsSince(page)).toEqual({ removed: 0, replaced: false, moved: [] });
      });

      test("an open select pop-up never makes the document scroll and stays at its anchor", async () => {
        await open(page, "appearance");
        const control = '[data-row-key="sidebar.sectionLook"] .ui-select-button';
        // The select near the bottom edge, as in the report.
        await page.evaluate((selector) => {
          const content = document.querySelector(".content")!;
          content.scrollTop += document.querySelector(selector)!.getBoundingClientRect().bottom - (innerHeight - 40);
        }, control);
        await page.click(control);
        await page.waitForSelector(".ui-select-popup");
        const problems: string[] = [];
        for (const delta of [200, 200, 200, -200, -200, -200, -200, -200, -200]) {
          await page.mouse.move(640, 100);
          await page.mouse.wheel(0, delta);
          await page.waitForTimeout(120);
          const state = await scrollState(page);
          const place = await page.evaluate((selector) => {
            const popup = document.querySelector(".ui-select-popup");
            if (!popup) return null;
            // Base UI keeps an open pop-up mounted; gone would mean the scroll closed it.
            const box = popup.getBoundingClientRect();
            const anchor = document.querySelector(selector)!.getBoundingClientRect();
            const content = document.querySelector(".content")!.getBoundingClientRect();
            return {
              shown: getComputedStyle(popup).visibility !== "hidden",
              onScreen: box.top >= 0 && box.bottom <= innerHeight,
              anchorShown: anchor.bottom > content.top && anchor.top < content.bottom,
              gap: Math.min(Math.abs(box.top - anchor.bottom), Math.abs(anchor.top - box.bottom)),
            };
          }, control);
          if (!place) problems.push(`wheel ${delta}: the pop-up closed`);
          if (state.documentScrolls) problems.push(`wheel ${delta}: document ${state.documentHeight}px`);
          // Shown, it is on screen; with its anchor scrolled away it may wait hidden.
          if (place?.shown && !place.onScreen)
            problems.push(`wheel ${delta}: pop-up off screen (anchor ${place.anchorShown ? "shown" : "hidden"})`);
          if (place?.anchorShown && (!place.shown || place.gap > 12))
            problems.push(`wheel ${delta}: pop-up ${place.gap}px from its anchor`);
        }
        await page.keyboard.press("Escape");
        expect(problems).toEqual([]);
      });

      test("opening a font list pushes no row down; its button closes it again", async () => {
        await open(page, "appearance");
        await watchRows(page);
        const button = '[data-row-key="terminal.fontFamily"] .domain-button';
        await page.click(button);
        await page.waitForSelector(".domain-option");
        expect((await rowsSince(page)).moved).toEqual([]);
        await page.click(button);
        await page.waitForSelector(".domain-option", { state: "detached" });
        expect(await page.getAttribute(button, "aria-expanded")).toBe("false");
      });

      test("the content's edges fade instead of clipping", async () => {
        await open(page, "appearance");
        const mask = await page.evaluate(() => {
          const style = getComputedStyle(document.querySelector(".content")!);
          return style.maskImage || style.getPropertyValue("-webkit-mask-image");
        });
        expect(mask).toContain("gradient");
      });
    });
  }
});
