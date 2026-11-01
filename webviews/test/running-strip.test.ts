// The tray line of a running command above the composer is quiet at rest and one box (Leo
// 2026-10-21, on a strip whose line was a filled pill inside the tray's bordered glass, with uneven
// insets: ""padding" this one tho i think is mostly a matter of like... well why is that even
// highlighted in the first place? you can click on it to go somewhere? is that a command or a
// subagent?").
// - At rest nothing inside the tray has a fill of its own. (The pill in the screenshot was the
//   line's hover: summary.css's opaque --acpmux-menu-hover at a 7px radius, inside the tray's 2px
//   padding.)
// - Hovering a line that opens something fills the whole line, its stop button included, out to
//   the tray's own edges (one inset, never a pill inside the strip), with the arrow cursor; the
//   line's button draws no second fill.
// - A line with nothing to open has no hover at all.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { openRunningTray } from "./support/openRunningTray";

await requireBrowserLane("running-strip.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("running-strip: skipping (run `bunx playwright install chromium`)");
    describe.skip("running strip", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/running-strip.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(clickable: boolean): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 760, height: 200 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
    await page.evaluate(
      (value) => (window as unknown as { __showTray: (c: boolean) => void }).__showTray(value),
      clickable,
    );
    await page.waitForSelector(".acpmux-running-tray .acpmux-agent-line");
    // The tray rises in as it joins the stack (bottomStack.css ui-enter): measure where it lands.
    return page;
  }

  /** The tray's descendants that paint a background of their own, by class. */
  const filled = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-running-tray *")]
        .filter((element) => {
          const color = getComputedStyle(element).backgroundColor;
          return color !== "rgba(0, 0, 0, 0)" && color !== "transparent";
        })
        .map((element) => element.className.toString() || element.tagName),
    );

  test("at rest nothing inside the tray has a fill", async () => {
    const page = await open(true);
    try {
      expect(await filled(page)).toEqual([]);
    } finally {
      await page.close();
    }
  });

  test("hover fills the whole line to the tray's edges, its stop button inside, with the arrow", async () => {
    const page = await open(true);
    try {
      await page.hover(".acpmux-agent-line__button");
      // One fill, on the line: its button draws none of its own (no box in a box).
      expect(await filled(page)).toEqual(["acpmux-agent-line"]);
      const geometry = await page.evaluate(() => {
        const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
        const line = document.querySelector<HTMLElement>(".acpmux-agent-line")!;
        const stop = line.querySelector<HTMLElement>(".acpmux-session-info-stop")!;
        const box = tray.getBoundingClientRect();
        const inner = {
          left: box.left + tray.clientLeft,
          right: box.left + tray.clientLeft + tray.clientWidth,
        };
        const rect = line.getBoundingClientRect();
        const stopRect = stop.getBoundingClientRect();
        return {
          left: rect.left - inner.left,
          right: inner.right - rect.right,
          stopInside: stopRect.left >= rect.left && stopRect.right <= rect.right,
          cursor: getComputedStyle(line.querySelector(".acpmux-agent-line__button")!).cursor,
        };
      });
      expect(geometry.left).toBeCloseTo(0, 1);
      expect(geometry.right).toBeCloseTo(0, 1);
      expect(geometry.stopInside).toBe(true);
      expect(geometry.cursor).toBe("default");
      // On the stop button the line keeps its one fill; the button only brightens.
      await page.hover(".acpmux-session-info-stop");
      expect(await filled(page)).toEqual(["acpmux-agent-line"]);
    } finally {
      await page.close();
    }
  });

  // Leo 2026-10-25: the collapse at the top "disappears for some reason at the top ... sometimes".
  // 120px squeezes the list to under three lines; 72px (the tray's 8px margin under it) leaves the
  // list no room, the two pinned rows only.
  for (const height of [400, 120, 72]) {
    test(`with 118 agents the header stays in view while the list scrolls (dock ${height}px)`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 600 } });
      try {
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
        await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
        await page.evaluate(
          (value) => (window as unknown as { __showPanel: (h: number) => void }).__showPanel(value),
          height,
        );
        await page.waitForSelector(".acpmux-running-tray__head");
        await openRunningTray(page);
        await page.click(".acpmux-running-tray__finished");
        await page.waitForFunction(
          () => document.querySelectorAll(".acpmux-running-tray li[data-finished]").length === 116,
        );
        // Scroll everything that can scroll to its end, the tray itself included, as a wheel would.
        const listHeight = await page.$eval(".acpmux-running-tray__list", (list) => list.clientHeight);
        await page.hover(listHeight > 0 ? ".acpmux-running-tray__list" : ".acpmux-running-tray__head");
        for (let step = 0; step < 20; step += 1) await page.mouse.wheel(0, 800);
        const state = await page.evaluate((h) => {
          const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
          const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
          const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
          tray.scrollTop = 10_000;
          const box = tray.getBoundingClientRect();
          const rect = head.getBoundingClientRect();
          const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
          const more = tray.querySelector<HTMLElement>(".acpmux-running-tray__finished")!.getBoundingClientRect();
          return {
            moreInside: more.height > 20 && more.bottom <= box.bottom + 0.5,
            // The list really scrolls wherever it has room; at the tightest squeeze it may have none.
            listScrolled:
              list.scrollHeight > list.clientHeight && (list.clientHeight === 0 ? h === 72 : list.scrollTop > 0),
            trayScroll: tray.scrollTop,
            headTop: rect.top - box.top,
            headHeight: rect.height,
            headDrawn: !!hit && head.contains(hit),
          };
        }, height);
        expect(state.listScrolled).toBe(true);
        expect(state.trayScroll).toBe(0);
        expect(state.headTop).toBeCloseTo(0, 0);
        expect(state.headHeight).toBeGreaterThan(20);
        expect(state.headDrawn).toBe(true);
        // View all stays whole at the tray's foot, even where the list has no room left.
        expect(state.moreInside).toBe(true);
      } finally {
        await page.close();
      }
    });
  }

  test("in a pane under 360px tall View all stays in reach: focus scrolls it into view", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 300 } });
    try {
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/running-strip.html`);
      await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
      await page.evaluate(() => (window as unknown as { __showPanel: (h: number) => void }).__showPanel(34));
      await page.waitForSelector(".acpmux-running-tray__head");
      await openRunningTray(page);
      await page.waitForSelector(".acpmux-running-tray__finished");
      await page.evaluate(() => {
        for (const animation of document.getAnimations())
          if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
      });
      await page.focus(".acpmux-running-tray__finished");
      const seen = await page.evaluate(() => {
        const tray = document.querySelector<HTMLElement>(".acpmux-running-tray")!;
        const more = tray.querySelector<HTMLElement>(".acpmux-running-tray__finished")!;
        const box = tray.getBoundingClientRect();
        const rect = more.getBoundingClientRect();
        const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
        return {
          inside: rect.top >= box.top - 0.5 && rect.bottom <= box.bottom + 0.5,
          drawn: !!hit && more.contains(hit),
        };
      });
      expect(seen).toEqual({ inside: true, drawn: true });
      await page.keyboard.press("Enter");
      expect(await page.$eval(".acpmux-running-tray__finished", (more) => more.getAttribute("aria-expanded"))).toBe(
        "true",
      );
    } finally {
      await page.close();
    }
  });

  test("a line with nothing to open has no hover and no hand", async () => {
    const page = await open(false);
    try {
      await page.hover(".acpmux-agent-line__button", { force: true });
      expect(await filled(page)).toEqual([]);
      expect(await page.$eval(".acpmux-agent-line__button", (button) => getComputedStyle(button).cursor)).not.toBe(
        "pointer",
      );
    } finally {
      await page.close();
    }
  });
});
