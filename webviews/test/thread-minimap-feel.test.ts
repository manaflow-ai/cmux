// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The thread minimap's feel in a long chat, in Chromium, against the Codex desktop app's prompt rail
// (minimap-ref SPEC). Leo, 2026-10-19: the rail "doesn't feel good like codex's". These pin what
// measured worse than Codex in a 60-turn chat:
// - a jump lands the prompt's bubble 35 px below the top, also when the rows it crosses were never
//   drawn (it landed 262 px above the view, for a prompt 50 turns up);
// - the hover card opens 250 ms after the pointer reaches the rail, as Codex's does (it took 465 ms),
//   while the tick magnifies at once;
// - the band of lit rows follows the scroll on the scroll's own frame (it lagged 1-2 frames and lit
//   a turn still below the view), with the turns on screen as Codex counts them;
// - older turns that load above the reader leave the band where it is on screen (it moved 150 px in
//   one frame).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-feel.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const paragraph = "The answer goes on for a while so the turn has real height in the transcript, as replies do.";
  /// Turns `from` to `to`, with replies of 1 to 9 paragraphs: turns of very different heights, as a
  /// real chat's are, so the layout's estimates for undrawn rows are off.
  const turns = (from: number, to: number) =>
    Array.from({ length: to - from }, (_, offset) => {
      const index = from + offset;
      const paragraphs = 1 + ((index * 7) % 5) * 2;
      return [
        row(`t${index}-user`, "user", `Prompt number ${index + 1}: look at part ${index + 1} of the plan.`),
        row(`t${index}-answer`, "assistant", Array.from({ length: paragraphs }, () => paragraph).join("\n\n")),
        row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
      ];
    }).flat();
  const COUNT = 60;

  async function open(rows: unknown[], top: number): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.waitForSelector(".acpmux-minimap__tick");
    await page.evaluate(
      async ({ to, count }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = to;
        await new Promise((resolve) => setTimeout(resolve, 400));
        const probe = window as unknown as Record<string, unknown>;
        /// The rows lit as on screen.
        probe.__lit = () =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")]
            .filter((tick) => tick.getAttribute("aria-current") === "true")
            .map((tick) => Number(tick.dataset.tick))
            .join(",");
        /// The turns on screen, from the drawn rows, as Codex's IntersectionObserver counts them
        /// (root margin -16 px at the top): a turn runs from its prompt to the next one.
        probe.__onScreen = () => {
          const view = scroller.getBoundingClientRect();
          const prompts = new Map<number, number>();
          for (const node of document.querySelectorAll<HTMLElement>(".acpmux-row.acpmux-user"))
            prompts.set(
              Number(node.dataset.rowId!.replace(/^t(\d+)-user$/, "$1")),
              node.getBoundingClientRect().top - view.top,
            );
          const shown: number[] = [];
          const indices = [...prompts.keys()].sort((a, b) => a - b);
          const first = indices[0]!;
          // The turn before the first drawn prompt reaches into the view when that prompt is below its top.
          if (first > 0 && prompts.get(first)! > 16) shown.push(first - 1);
          for (const index of indices) {
            const y = prompts.get(index)!;
            const next = prompts.get(index + 1);
            const ends = index === count - 1 ? Infinity : (next ?? Infinity);
            if (y < view.height && ends > 16) shown.push(index);
          }
          return [...new Set(shown)].sort((a, b) => a - b).join(",");
        };
        /// The bar's drawn length.
        probe.__length = (index: number) =>
          document.querySelector<HTMLElement>(`[data-tick="${index}"] .acpmux-minimap__bar`)!.getBoundingClientRect().width;
        probe.__card = () => document.querySelector(".acpmux-minimap__card") !== null;
      },
      { to: top, count: COUNT },
    );
    return page;
  }
  const tickPoint = (page: Page, index: number) =>
    page.evaluate((at) => {
      const box = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
      return { x: box.left + 6, y: box.top + box.height / 2 };
    }, index);
  /// The prompt's bubble's top below the transcript's top, once drawn.
  const landing = (page: Page, index: number) =>
    page.evaluate((at) => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      const bubble = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="t${at}-user"] .cv-user__bubble`);
      return bubble ? bubble.getBoundingClientRect().top - view.top : null;
    }, index);
  /// The first row the rail's list shows (it scrolls past 57 rows in this window).
  const firstVisibleTick = (page: Page) =>
    page.evaluate(() => {
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!.getBoundingClientRect();
      const ticks = [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")];
      return Number(ticks.find((tick) => tick.getBoundingClientRect().top >= list.top + 45)!.dataset.tick);
    });

  describe("thread minimap feel (Chromium)", () => {
    test("a click lands the prompt's bubble 35 px down, near or far, drawn or not", async () => {
      const page = await open(turns(0, COUNT), 9000);
      // Near: a drawn prompt about 600 px down, on the smooth scroll.
      const near = await page.evaluate(() => {
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const prompt = [...document.querySelectorAll<HTMLElement>(".acpmux-row.acpmux-user")].find(
          (node) => node.getBoundingClientRect().top - view.top > 600,
        )!;
        return Number(prompt.dataset.rowId!.replace(/^t(\d+)-user$/, "$1"));
      });
      let point = await tickPoint(page, near);
      await page.mouse.click(point.x, point.y);
      await page.waitForTimeout(1_200);
      expect(Math.abs((await landing(page, near))! - 35)).toBeLessThanOrEqual(1);
      // Far: a prompt about fifty turns up, never drawn, whose rows' heights are estimates.
      const far = await firstVisibleTick(page);
      expect(near - far).toBeGreaterThan(20);
      point = await tickPoint(page, far);
      await page.mouse.click(point.x, point.y);
      await page.waitForTimeout(1_500);
      const landed = await landing(page, far);
      expect(landed).not.toBeNull();
      expect(Math.abs(landed! - 35)).toBeLessThanOrEqual(1);
      // And the band agrees with where it landed.
      expect(await page.evaluate(() => (window as any).__lit())).toBe(
        await page.evaluate(() => (window as any).__onScreen()),
      );
      await page.close();
    });

    test("hovering magnifies at once and opens the card 250 ms after the pointer reaches the rail", async () => {
      const page = await open(turns(0, COUNT), 9000);
      const point = await tickPoint(page, 30);
      await page.mouse.move(point.x + 400, point.y);
      await page.waitForTimeout(700);
      await page.evaluate(() => {
        const probe = window as any;
        probe.__frames = [];
        document.addEventListener("pointerover", () => (probe.__over = performance.now()), { once: true, capture: true });
        const step = () => {
          probe.__frames.push({ t: performance.now(), length: probe.__length(30), card: probe.__card() });
          if (probe.__frames.length < 60) requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
      });
      await page.mouse.move(point.x, point.y);
      await page.waitForTimeout(1_200);
      const { over, frames } = await page.evaluate(() => ({
        over: (window as any).__over as number,
        frames: (window as any).__frames as { t: number; length: number; card: boolean }[],
      }));
      const after = frames.filter((frame) => frame.t >= over);
      const grows = after.find((frame) => frame.length > 6.5)!;
      const opens = after.find((frame) => frame.card)!;
      // No dwell before the fisheye: it starts within two frames.
      expect(grows.t - over).toBeLessThan(40);
      // The card: Codex's 250 ms (its frames show 267-283 ms with the render), not the app's 450.
      expect(opens.t - over).toBeGreaterThan(230);
      expect(opens.t - over).toBeLessThan(330);
      await page.close();
    });

    test("the band of lit rows follows the scroll on the scroll's own frame", async () => {
      const page = await open(turns(0, COUNT), 9000);
      await page.mouse.move(640, 400);
      await page.evaluate(() => {
        const probe = window as any;
        probe.__frames = [];
        probe.__tracking = true;
        const step = () => {
          probe.__frames.push({ lit: probe.__lit(), shown: probe.__onScreen() });
          if (probe.__tracking) requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
      });
      for (let index = 0; index < 80; index += 1) {
        await page.mouse.wheel(0, index < 40 ? 60 : -60);
        await page.waitForTimeout(8);
      }
      await page.waitForTimeout(300);
      const frames = await page.evaluate(() => {
        const probe = window as any;
        probe.__tracking = false;
        return probe.__frames as { lit: string; shown: string }[];
      });
      const moves = frames.filter((frame, index) => index > 0 && frame.shown !== frames[index - 1]!.shown).length;
      expect(moves).toBeGreaterThan(10);
      const wrong = frames.filter((frame) => frame.lit !== frame.shown);
      expect(wrong).toEqual([]);
      await page.close();
    });

    test("older turns that load above the reader leave the band where it was on screen", async () => {
      // 30 turns at first, then the 30 before them: the rail grows from 300 px to its 57-row cap.
      for (const [loaded, more] of [
        [30, 30],
        [20, 10],
      ] as const) {
        const page = await open(turns(COUNT - loaded, COUNT), 3000);
        const before = await page.evaluate(() => {
          const lit = (window as any).__lit() as string;
          const first = Number(lit.split(",")[0]);
          return { lit, first, y: document.querySelector<HTMLElement>(`[data-tick="${first}"]`)!.getBoundingClientRect().top };
        });
        const frames = await page.evaluate(
          async ({ rows, key, total }) => {
            const probe = window as any;
            const seen: number[] = [];
            const count = () => document.querySelectorAll(".acpmux-minimap__tick").length;
            probe.__showRows(rows);
            // From the first frame that draws the new rows.
            for (let wait = 0; wait < 30 && count() !== total; wait += 1)
              await new Promise((resolve) => requestAnimationFrame(resolve));
            for (let index = 0; index < 20; index += 1) {
              const row = document.querySelector<HTMLElement>(`[data-tick="${key}"]`);
              seen.push(row ? row.getBoundingClientRect().top : NaN);
              await new Promise((resolve) => requestAnimationFrame(resolve));
            }
            return seen;
          },
          { rows: turns(COUNT - loaded - more, COUNT), key: before.first + more, total: loaded + more },
        );
        // The first frame with the new rows draws the band where it was; then it moves at most a few
        // px a frame (a glide, not a jump).
        expect(Math.abs(frames[0]! - before.y)).toBeLessThanOrEqual(1);
        for (let index = 1; index < frames.length; index += 1)
          expect(Math.abs(frames[index]! - frames[index - 1]!)).toBeLessThanOrEqual(40);
        await page.close();
      }
    });
  });
});
