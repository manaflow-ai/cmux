// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening a run of N commands costs the same at any N (Leo, 2026-11-06: "The tool call expansion,
// when it has several tool calls, I think sometimes it lags a bit"). Real Chromium opens "Ran N
// commands" at the bottom of a chat (ToolGroupSize.gallery.ts) for N = 5, 20 and 100, many times,
// and reads every painted frame from the click: when the first frame shows the opened body, when the
// fold is over (the box at its full height, unclipped) and when the steps the run's box shows are
// drawn. It asserts that the click's frame draws only about a view's worth of steps, that the box is
// as tall from the fold's end as once settled (no row pops in under the reader), that the box's steps
// are drawn soon after, and that a long run never draws more than its window (stepWindow.ts).
// TOOL_GROUP_COST=1 prints the p50/p95 table (the before and after numbers for a fix).
//
// Real Chromium from Playwright on the agent pane's gallery scene.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("tool-group-expand-cost.test.ts", async () => {
  const ENTRY = "agent-pane.tool-group-size";
  const SIZES = [5, 20, 100] as const;
  const REPS = Number(process.env.TOOL_GROUP_REPS ?? 15);
  setDefaultTimeout(300_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("tool-group-expand-cost: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "n5" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const ROW = '[data-row-id="tool-group-size-run"]';
  const GROUP = `${ROW} button[data-tool-group]`;

  /// Every finite animation over, then the scroller's offset and height the same over 8 painted frames.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < 8; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}:${document.querySelectorAll(".cv-step").length}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  async function open(variant: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(GROUP).waitFor();
    await settled(page);
    return page;
  }

  type Rep = {
    /// ms from the click to the first painted frame that shows the opened body.
    first: number;
    /// ms from the click to the first painted frame with the fold over: the box unclipped at its height.
    expanded: number;
    /// ms from the click to the first painted frame with the steps the run's box shows drawn.
    all: number;
    /// Steps drawn in the first frame that shows the body.
    firstSteps: number;
    /// The box's height on the fold's last frame and once every step is drawn.
    expandedHeight: number;
    finalHeight: number;
    /// Steps drawn once settled.
    finalSteps: number;
  };

  /// The steps the run's box shows at once (RunScroll.tsx, 224px of 22px lines), or all of a short run.
  const SHOWN = 10;

  /// Clicks the closed group's line and reads every painted frame until the fold is over and every
  /// step is drawn (or 3 s pass).
  const watchOpen = async (page: Page, n: number): Promise<Rep> => {
    const point = await page.evaluate((selector) => {
      const line = document.querySelector<HTMLElement>(selector)!;
      const box = line.getBoundingClientRect();
      return { x: box.left + Math.min(40, box.width / 2), y: box.top + box.height / 2 };
    }, GROUP);
    // Armed before the click, in its own round trip.
    await page.evaluate(() => {
      const scope = window as unknown as { costStart?: number };
      scope.costStart = 0;
      addEventListener("pointerdown", () => (scope.costStart = performance.now()), { capture: true, once: true });
    });
    const watching = page.evaluate(
      ({ row, n, shown }) =>
        new Promise<Rep>((resolve) => {
          const scope = window as unknown as { costStart?: number };
          const rep: Partial<Rep> = {};
          window.cmuxAfterPaint(() => {
            const start = scope.costStart ?? 0;
            if (!start) return;
            const at = performance.now() - start;
            const items = document.querySelector<HTMLElement>(`${row} [data-tool-group-items]`);
            const body = items?.parentElement;
            if (!items || !body) return at < 3000 ? undefined : (resolve(rep as Rep), false);
            const steps = items.querySelectorAll(".cv-step").length;
            const height = body.getBoundingClientRect().height;
            if (rep.first === undefined) {
              rep.first = at;
              rep.firstSteps = steps;
            }
            const folding =
              body.hasAttribute("data-fold-clip") || body.getAnimations().some((each) => each.playState === "running");
            if (rep.expanded === undefined && !folding) {
              rep.expanded = at;
              rep.expandedHeight = height;
            }
            if (rep.all === undefined && steps >= Math.min(n, shown)) rep.all = at;
            if ((rep.expanded !== undefined && rep.all !== undefined) || at > 3000) {
              rep.finalHeight = height;
              resolve(rep as Rep);
              return false;
            }
          });
        }),
      { row: ROW, n, shown: SHOWN },
    );
    await page.mouse.click(point.x, point.y);
    const rep = await watching;
    await settled(page);
    const final = await page.evaluate((row) => {
      const items = document.querySelector<HTMLElement>(`${row} [data-tool-group-items]`)!;
      return {
        height: items.parentElement!.getBoundingClientRect().height,
        steps: items.querySelectorAll(".cv-step").length,
      };
    }, ROW);
    rep.finalHeight = final.height;
    rep.finalSteps = final.steps;
    return rep;
  };

  const close = async (page: Page) => {
    await page.locator(GROUP).click();
    await page.waitForFunction(
      (selector) => document.querySelector(selector)?.getAttribute("aria-expanded") === "false",
      GROUP,
    );
    await settled(page);
    // Back to the very end with the reader's wheel (the pointer near the transcript's top-left, clear
    // of the floating jump-to-latest button), so each open starts from one place.
    const scroller = page.locator(".acpmux-scroll");
    const view = (await scroller.boundingBox())!;
    await page.mouse.move(view.x + 8, view.y + 8);
    for (
      let notch = 0;
      notch < 100 && (await scroller.evaluate((node) => node.scrollTop + node.clientHeight < node.scrollHeight - 1));
      notch++
    ) {
      await page.mouse.wheel(0, 2_000);
      await settled(page);
    }
    await settled(page);
  };

  const pct = (values: number[], p: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)]!;
  };

  const table: string[] = [];
  afterAll(() => {
    if (process.env.TOOL_GROUP_COST !== "1") return;
    console.log(
      [
        "tool-group-expand-cost (ms from click; p50 / p95)",
        "N    | first frame   | fold over     | box's steps   | steps in first frame | steps settled",
        ...table,
      ].join("\n"),
    );
  });

  for (const n of SIZES)
    test(`opening "Ran ${n} commands" draws a view's worth first, at its whole height`, async () => {
      const page = await open(`n${n}`);
      expect(await page.locator(GROUP).getAttribute("aria-expanded")).toBe("false");
      // One open and close first, so the page's code is warm before any rep counts.
      await watchOpen(page, n);
      await close(page);
      const reps: Rep[] = [];
      for (let rep = 0; rep < REPS; rep++) {
        reps.push(await watchOpen(page, n));
        await close(page);
      }
      await page.close();
      const col = (pick: (rep: Rep) => number) => {
        const values = reps.map(pick);
        return `${pct(values, 50).toFixed(1).padStart(6)} / ${pct(values, 95).toFixed(1).padStart(6)}`;
      };
      table.push(
        `${String(n).padEnd(4)} | ${col((r) => r.first)} | ${col((r) => r.expanded)} | ${col((r) => r.all)} | ${String(Math.max(...reps.map((r) => r.firstSteps))).padEnd(20)} | ${Math.max(...reps.map((r) => r.finalSteps))}`,
      );
      for (const [index, rep] of reps.entries()) {
        const at = { n, index, ...rep };
        // The steps the box shows are drawn, soon after the fold.
        expect({ at, all: rep.all !== undefined && rep.all < 2000 }).toEqual({ at, all: true });
        // A long run draws its window and no more, at any length: a short one draws every step.
        expect({ at, windowed: rep.finalSteps <= 40 && rep.finalSteps >= Math.min(n, SHOWN) }).toEqual({
          at,
          windowed: true,
        });
        // The box the fold ends at is the box with every step: no row pops in under it after.
        expect({ at, whole: Math.abs(rep.expandedHeight - rep.finalHeight) <= 1 }).toEqual({ at, whole: true });
        // The click's frame draws about a view's worth of steps, never all of a long run.
        expect({ at, bounded: rep.firstSteps <= 40 }).toEqual({ at, bounded: true });
      }
    });

  // Rows of mixed heights (a long lead thought, failures, later thoughts, images) that the run's box
  // brings in as it scrolls take their own heights: 0 px of drift. Every step keeps its place in the
  // box's content (its top in the box plus the box's offset), the run's own row its top and height in
  // the transcript's content, and every other row in view its place on screen, as rows mount and are
  // measured (stepWindow.ts `measure`, review of cmux#37152). The reader's own input drives it: a
  // click opens the run and wheel notches scroll the transcript and then the box. A synthetic wheel
  // plus scrollTop writes can leave the transcript following the latest row while it sits above it,
  // and its follow-latest pass (VirtualTranscript.tsx `settleFollowBottom`) then snaps it back down,
  // which real input never does. The notches aim near the box's top-left corner, clear of the
  // floating jump-to-latest button, and stop at the box's end, where the next notch would chain to
  // the transcript as the browser chains any scroll.
  // (Reads never group since 2026-11-17, readPath.ts: no run of reads to open.)
  for (const variant of ["n100", "mixed-commands"] as const)
    test(`${variant}: scrolling the opened run's box moves nothing in view`, async () => {
      const page = await open(variant);
      const group = (await page.locator(GROUP).boundingBox())!;
      await page.mouse.click(group.x + group.width / 2, group.y + group.height / 2);
      await page.waitForFunction(
        (row) => {
          const body = document.querySelector<HTMLElement>(`${row} [data-tool-group-items]`)?.parentElement;
          return (
            body &&
            !body.hasAttribute("data-fold-clip") &&
            body.getAnimations().every((each) => each.playState !== "running")
          );
        },
        ROW,
        { timeout: 10_000 },
      );
      // The reader wheels the transcript (the pointer over its left edge, off the box) until the run's
      // box sits mid-view, the reply under it in view.
      for (let notch = 0; notch < 100; notch++) {
        const { off, x, y } = await page.evaluate((row) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const box = document.querySelector<HTMLElement>(`${row} .cv-run-scroll`)!.getBoundingClientRect();
          const view = scroller.getBoundingClientRect();
          return {
            off: box.top + box.height / 2 - (view.top + scroller.clientHeight / 2),
            x: view.left + 8,
            y: view.top + 8,
          };
        }, ROW);
        if (Math.abs(off) < 60) break;
        await page.mouse.move(x, y);
        await page.mouse.wheel(0, Math.sign(off) * Math.min(Math.abs(off), 120));
        await settled(page);
      }
      await settled(page);
      await page.evaluate(
        ({ row, TRANSCRIPT_ROW }) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const box = document.querySelector<HTMLElement>(`${row} .cv-run-scroll`)!;
          /// Every other transcript row in view by its viewport top, and every drawn step by its top in
          /// the box's content.
          const places = () => {
            const view = scroller.getBoundingClientRect();
            const inside = box.getBoundingClientRect();
            const tops = new Map<string, number>();
            for (const each of scroller.querySelectorAll<HTMLElement>(TRANSCRIPT_ROW)) {
              const rect = each.getBoundingClientRect();
              if (each.matches(row) || rect.bottom <= view.top + 1 || rect.top >= view.bottom - 1) continue;
              tops.set(`row:${each.dataset.rowId}`, rect.top);
            }
            const own = document.querySelector<HTMLElement>(row)!.getBoundingClientRect();
            tops.set("own:top", own.top - view.top + scroller.scrollTop);
            tops.set("own:height", own.height);
            for (const step of box.querySelectorAll<HTMLElement>("[data-step]"))
              tops.set(`step:${step.dataset.step}`, step.getBoundingClientRect().top - inside.top + box.scrollTop);
            return tops;
          };
          const seen = { moves: [] as string[], mounted: 0, rowsInView: 0, last: places() };
          seen.rowsInView = [...seen.last.keys()].filter((key) => key.startsWith("row:")).length;
          (window as unknown as { __noJump: unknown }).__noJump = {
            seen,
            check(what: string) {
              const now = places();
              for (const [key, top] of now) {
                const before = seen.last.get(key);
                if (before !== undefined && Math.abs(top - before) > 0.5)
                  seen.moves.push(`${what} ${key} ${before.toFixed(1)}->${top.toFixed(1)}`);
              }
              seen.last = now;
              seen.mounted = Math.max(seen.mounted, box.querySelectorAll("[data-step]").length);
            },
            atEnd: () => box.scrollTop + box.clientHeight >= box.scrollHeight - 1,
            corner: () => {
              const rect = box.getBoundingClientRect();
              return { x: rect.left + 12, y: rect.top + 12 };
            },
          };
        },
        { row: ROW, TRANSCRIPT_ROW },
      );
      type Probe = {
        __noJump: {
          seen: { moves: string[]; mounted: number; rowsInView: number };
          check(what: string): void;
          atEnd(): boolean;
          corner(): { x: number; y: number };
        };
      };
      /// Two painted frames, then every place compared with the last.
      const check = (what: string) =>
        page.evaluate(async (what) => {
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
          (window as unknown as Probe).__noJump.check(what);
        }, what);
      const corner = await page.evaluate(() => (window as unknown as Probe).__noJump.corner());
      await page.mouse.move(corner.x, corner.y);
      // A 60 px wheel notch at a time, to the box's end.
      let scrolls = 0;
      for (
        let guard = 0;
        guard < 200 && !(await page.evaluate(() => (window as unknown as Probe).__noJump.atEnd()));
        guard++
      ) {
        await page.mouse.wheel(0, 60);
        scrolls += 1;
        await check(`scroll ${scrolls}`);
      }
      for (let frame = 0; frame < 4; frame++) await check("after");
      const seen = {
        scrolls,
        ...(await page.evaluate(() => {
          const { moves, mounted, rowsInView } = (window as unknown as Probe).__noJump.seen;
          return { moves, mounted, rowsInView };
        })),
      };

      await page.close();
      if (process.env.TOOL_GROUP_COST === "1") console.log(`no-jump ${variant} ${JSON.stringify(seen)}`);
      expect({
        variant,
        scrolled: seen.scrolls > 5,
        inView: seen.rowsInView > 0,
        windowed: seen.mounted <= 40,
      }).toEqual({
        variant,
        scrolled: true,
        inView: true,
        windowed: true,
      });
      // The run's steps, its own row and every other row in view: 0 px.
      expect({ variant, moves: seen.moves }).toEqual({ variant, moves: [] });
    });

  // Opened at 1,000 and 10,000 commands, the run mounts the same steps and DOM nodes within 10%, and
  // no more than its box and a box's height over and under it hold; the row is as tall at both.
  test("an opened run of 1,000 or 10,000 commands mounts the same window and nodes", async () => {
    const at = async (n: number) => {
      const page = await open(`n${n}`);
      await page.locator(GROUP).click();
      await settled(page);
      const seen = await page.evaluate((row) => {
        const node = document.querySelector<HTMLElement>(row)!;
        return {
          steps: node.querySelectorAll("[data-tool-group-items] > .cv-step").length,
          nodes: node.querySelectorAll("*").length,
          height: node.getBoundingClientRect().height,
        };
      }, ROW);
      await page.close();
      return seen;
    };
    const thousand = await at(1_000);
    if (process.env.TOOL_GROUP_COST === "1") console.log(`window n1000 ${JSON.stringify(thousand)}`);
    expect(thousand.steps).toBeLessThanOrEqual(40);
    const tenThousand = await at(10_000);
    if (process.env.TOOL_GROUP_COST === "1") console.log(`window n10000 ${JSON.stringify(tenThousand)}`);
    expect(tenThousand.steps).toBeLessThanOrEqual(40);
    expect(Math.abs(tenThousand.nodes - thousand.nodes)).toBeLessThanOrEqual(thousand.nodes * 0.1);
    expect(tenThousand.height).toBe(thousand.height);
  });
});
