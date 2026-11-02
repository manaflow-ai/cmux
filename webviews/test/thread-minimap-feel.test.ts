// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The thread minimap's feel in a long chat, in Chromium, against the Codex desktop app's prompt rail
// (minimap-ref SPEC). Leo, 2026-10-19: the rail "doesn't feel good like codex's". These pin what
// measured worse than Codex in a 60-turn chat:
// - a jump lands the prompt's bubble 35 px below the top, also when the rows it crosses were never
//   drawn (it landed 262 px above the view, for a prompt 50 turns up);
// - the hover card opens with the tick's magnification, on the pointer's own commit (Leo,
//   2026-10-29: "faster scrttoll/hover over"; it waited Codex's 250 ms, and 465 ms before that);
// - a click lands the prompt in the frame of the click, with no glide;
// - the band of lit rows follows the scroll on the scroll's own frame (it lagged 1-2 frames and lit
//   a turn still below the view), with the turns on screen as Codex counts them;
// - older turns that load above the reader leave the band where it is on screen (it moved 150 px in
//   one frame).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { SHIFT_MS, STEP_CURVE } from "../src/agent-session/acpmux/threadMinimap/model";
import { installPaintedFrames } from "./support/paintedFrames";
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
  /// How far the minimap's SHIFT_MS glide over `distance` px moves in a 60 Hz frame at its fastest
  /// speed: no 60 Hz frame of the glide moves more, nor does a path read off frames between.
  const glideStep = (distance: number) => {
    const [x1, y1, x2, y2] = STEP_CURVE;
    const along = (t: number, a: number, b: number) => 3 * a * t * (1 - t) ** 2 + 3 * b * t * t * (1 - t) + t ** 3;
    const eased = (x: number) => {
      let [lo, hi] = [0, 1];
      for (let step = 0; step < 40; step += 1)
        if (along((lo + hi) / 2, x1, x2) < x) lo = (lo + hi) / 2;
        else hi = (lo + hi) / 2;
      return along((lo + hi) / 2, y1, y2);
    };
    let fastest = 0;
    for (let at = 0; at < SHIFT_MS; at += 0.25)
      fastest = Math.max(fastest, (eased((at + 0.25) / SHIFT_MS) - eased(at / SHIFT_MS)) / 0.25);
    return (fastest * distance * 1000) / 60;
  };

  async function open(rows: unknown[], top: number, count = COUNT, height = 820): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.waitForSelector(".acpmux-minimap__tick");
    await page.evaluate(
      async ({ to, count }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const probe = window as unknown as Record<string, unknown>;
        /// Resolves once the transcript's offset has held for `frames` painted frames (rows measure,
        /// then rest).
        probe.__still = async (frames = 6) => {
          let last = NaN;
          let held = 0;
          for (let index = 0; index < 300 && held < frames; index += 1) {
            await window.cmuxPaintFrame();
            held = scroller.scrollTop === last ? held + 1 : 0;
            last = scroller.scrollTop;
          }
        };
        scroller.scrollTop = to;
        await (probe.__still as () => Promise<void>)();
        /// The rows lit as on screen.
        probe.__lit = () =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")]
            .filter((tick) => tick.getAttribute("aria-current") === "true")
            .map((tick) => Number(tick.dataset.tick))
            .join(",");
        /// The turns on screen, from the drawn rows, as Codex's IntersectionObserver counts them: a turn
        /// runs from 35 px above its prompt to 35 px above the next one, and the root's top margin is
        /// -16 px, so a turn stops counting once the next prompt is within 51 px of the top.
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
          indices.forEach((index, at) => {
            const y = prompts.get(index)!;
            // The turn before a drawn prompt whose own prompt is not drawn reaches into the view when
            // this prompt is below its top.
            if (index > 0 && !prompts.has(index - 1) && y > 51 && y < view.height) shown.push(index - 1);
            // A turn ends at the next drawn prompt (the turns between lie between); a row drawn far
            // above the view, its next prompt not drawn, ends there too.
            const next = indices[at + 1];
            // A prompt above the view whose next prompt is not drawn, while a later one is, ends above it.
            if (y < 0 && next !== undefined && next !== index + 1) return;
            const ends = index === count - 1 || next === undefined ? Infinity : prompts.get(next)!;
            if (y < view.height && ends > 51) shown.push(index);
          });
          return [...new Set(shown)].sort((a, b) => a - b).join(",");
        };
        /// The bar's drawn length.
        probe.__length = (index: number) =>
          document.querySelector<HTMLElement>(`[data-tick="${index}"] .acpmux-minimap__bar`)!.getBoundingClientRect()
            .width;
        probe.__card = () => document.querySelector(".acpmux-minimap__card") !== null;
      },
      { to: top, count },
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
  /// Waits for a jump to `index` to come to rest, then says where its bubble landed.
  const landed = async (page: Page, index: number) => {
    await page.evaluate(() => (window as any).__still(8));
    return landing(page, index);
  };
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
      // Near: a drawn prompt about 600 px down. It lands with the click itself, before any frame of
      // motion (no glide: Leo, 2026-10-29, "faster scrttoll").
      const near = await page.evaluate(() => {
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const prompt = [...document.querySelectorAll<HTMLElement>(".acpmux-row.acpmux-user")].find(
          (node) => node.getBoundingClientRect().top - view.top > 600,
        )!;
        return Number(prompt.dataset.rowId!.replace(/^t(\d+)-user$/, "$1"));
      });
      let point = await tickPoint(page, near);
      await page.mouse.click(point.x, point.y);
      expect(Math.abs((await landing(page, near))! - 35)).toBeLessThanOrEqual(1);
      expect(Math.abs((await landed(page, near))! - 35)).toBeLessThanOrEqual(1);
      // Far: a prompt well up the chat, never drawn, whose rows' heights are estimates.
      const far = await firstVisibleTick(page);
      expect(near - far).toBeGreaterThan(10);
      point = await tickPoint(page, far);
      await page.mouse.click(point.x, point.y);
      const farLanding = await landed(page, far);
      expect(farLanding).not.toBeNull();
      expect(Math.abs(farLanding! - 35)).toBeLessThanOrEqual(1);
      // And the band agrees with where it landed.
      expect(await page.evaluate(() => (window as any).__lit())).toBe(
        await page.evaluate(() => (window as any).__onScreen()),
      );
      await page.close();
    });

    test("hovering magnifies and opens the card at once", async () => {
      const page = await open(turns(0, COUNT), 9000);
      const point = await tickPoint(page, 30);
      await page.mouse.move(point.x + 400, point.y);
      await page.waitForFunction(() => !(window as any).__card());
      await page.evaluate(() => {
        const probe = window as any;
        probe.__frames = [];
        document.addEventListener("pointerover", () => (probe.__over = performance.now()), {
          once: true,
          capture: true,
        });
        // When the rail commits the hover and the card, to the ms: a frame's time would measure the
        // runner's frame rate.
        const rail = document.querySelector(".acpmux-minimap__rail")!;
        new MutationObserver(() => {
          probe.__hovering ??= rail.hasAttribute("data-hovering") ? performance.now() : undefined;
          probe.__carded ??= probe.__card() ? performance.now() : undefined;
        }).observe(document.body, {
          attributes: true,
          attributeFilter: ["data-hovering"],
          childList: true,
          subtree: true,
        });
        window.cmuxAfterPaint(() => {
          probe.__frames.push({ t: performance.now(), length: probe.__length(30), card: probe.__card() });
          return probe.__frames.length < 60;
        });
      });
      await page.mouse.move(point.x, point.y);
      await page.waitForFunction(() => (window as any).__frames.length >= 60);
      const { over, hovering, carded, frames } = await page.evaluate(() => ({
        over: (window as any).__over as number,
        hovering: (window as any).__hovering as number,
        carded: (window as any).__carded as number,
        frames: (window as any).__frames as { t: number; length: number; card: boolean }[],
      }));
      const after = frames.filter((frame) => frame.t >= over);
      const grows = after.find((frame) => frame.length > 6.5);
      const opens = after.find((frame) => frame.card);
      expect(grows).toBeDefined();
      expect(opens).toBeDefined();
      // Times are the commits', and painting is counted in frames: a runner that paints every 100 ms
      // would otherwise fail a rail with no dwell.
      // No dwell before the fisheye (CSS :hover is no faster): the rail takes the hover before the
      // second painted frame after the pointer arrives (React commits it in a task of its own, so at
      // 60 Hz a dwell over ~30 ms fails), and the tick grows within 4 painted frames of that (70 ms at
      // 60 Hz; its composited transition is made on the first and starts on the second).
      expect(frames.filter((frame) => frame.t >= over && frame.t < hovering).length).toBeLessThanOrEqual(1);
      const growsAt = frames.filter((frame) => frame.t >= hovering).indexOf(grows!);
      expect(growsAt).toBeGreaterThanOrEqual(0);
      expect(growsAt).toBeLessThan(4);
      // The card: no dwell. It commits before the second painted frame after the pointer arrives, as
      // the hover does, and paints by the second frame after its commit.
      expect(frames.filter((frame) => frame.t >= over && frame.t < carded).length).toBeLessThanOrEqual(1);
      const opensAt = frames.filter((frame) => frame.t >= carded).indexOf(opens!);
      expect(opensAt).toBeGreaterThanOrEqual(0);
      expect(opensAt).toBeLessThan(2);
      await page.close();
    });

    test("the band of lit rows follows the scroll on the scroll's own frame", async () => {
      const page = await open(turns(0, COUNT), 9000);
      await page.mouse.move(640, 400);
      await page.evaluate(() => {
        const probe = window as any;
        probe.__frames = [];
        probe.__tracking = true;
        window.cmuxAfterPaint(() => {
          probe.__frames.push({ lit: probe.__lit(), shown: probe.__onScreen() });
          return probe.__tracking;
        });
      });
      for (let index = 0; index < 80; index += 1) {
        await page.mouse.wheel(0, index < 40 ? 60 : -60);
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      await page.evaluate(() => (window as any).__still(10));
      const frames = await page.evaluate(() => {
        const probe = window as any;
        probe.__tracking = false;
        return probe.__frames as { lit: string; shown: string }[];
      });
      const moves = frames.filter((frame, index) => index > 0 && frame.shown !== frames[index - 1]!.shown).length;
      expect(moves).toBeGreaterThan(10);
      // One stray frame is allowed: a runner can paint between a scroll and its event.
      const wrong = frames.filter((frame) => frame.lit !== frame.shown);
      expect(wrong.length).toBeLessThanOrEqual(1);
      await page.close();
    });

    test("older turns that load above the reader leave the band where it was on screen", async () => {
      // [turns loaded, turns that arrive above them, the transcript's offset]:
      // - 30, then 30 more: the rail grows from 300 px to its 57-row cap and glides back to center;
      // - 20, then 10 more: a rail that grows and stays under its cap;
      // - 90, then 30 more: a rail that already scrolls (past the default rail's 92% cap,
      //   46c2c649311e), with the band in its top third: its own scroll takes the new rows and the
      //   band does not move at all.
      for (const [loaded, more, offset] of [
        [30, 30, 3000],
        [20, 10, 3000],
        [90, 30, 300],
      ] as const) {
        const total = loaded + more;
        const page = await open(turns(total - loaded, total), offset, total);
        const before = await page.evaluate(() => {
          const lit = (window as any).__lit() as string;
          const first = Number(lit.split(",")[0]);
          const list = document.querySelector<HTMLElement>(".acpmux-minimap__list");
          return {
            lit,
            first,
            y: document.querySelector<HTMLElement>(`[data-tick="${first}"]`)!.getBoundingClientRect().top,
            scrolls: !!list && list.scrollHeight > list.clientHeight + 1,
          };
        });
        // The page's animations run 10 times slower, so the glide spans enough frames to be seen on
        // a runner that paints every 100 ms; its speed is checked in the timeline's (slowed) time.
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Animation.enable");
        await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.1 });
        const frames = await page.evaluate(
          async ({ rows, key, total: count, sampleMs }) => {
            const probe = window as any;
            const seen: { y: number; lit: string; t: number }[] = [];
            // The rail draws only the ticks in its view (tickWindow.ts, 8c3dac1aad59), so a long one
            // never draws all of them: each entry carries the count of the rail it was drawn for.
            const ticks = () =>
              Number(document.querySelector(".acpmux-minimap__entry")?.getAttribute("aria-setsize") ?? 0);
            probe.__showRows(rows);
            // From the first frame that draws the new rows.
            for (let wait = 0; wait < 30 && ticks() !== count; wait += 1) await window.cmuxPaintFrame();
            const start = performance.now();
            for (let index = 0; index < 600 && (index < 20 || performance.now() - start < sampleMs); index += 1) {
              const row = document.querySelector<HTMLElement>(`[data-tick="${key}"]`);
              // The timeline's time is the painted frame's, which the glide follows.
              seen.push({
                y: row ? row.getBoundingClientRect().top : NaN,
                lit: probe.__lit(),
                t: document.timeline.currentTime as number,
              });
              await window.cmuxPaintFrame();
            }
            return seen;
          },
          { rows: turns(0, total), key: before.first + more, total, sampleMs: SHIFT_MS * 10 * 1.25 },
        );
        const shifted = before.lit
          .split(",")
          .map((index) => Number(index) + more)
          .join(",");
        // Every frame found the band's row (NaN: a frame drew no row for it).
        expect(frames.findIndex((frame) => Number.isNaN(frame.y))).toBe(-1);
        // The first frame with the new rows draws the same turns lit, where they were; then the band
        // moves in any 60 Hz frame of the timeline's time no more than SHIFT_MS's glide does at its
        // fastest speed (a glide, not a jump: 46 px of 137 at 200 ms, where a jump is 137), read off
        // the painted frames' path.
        expect(frames[0]!.lit).toBe(shifted);
        expect(Math.abs(frames[0]!.y - before.y)).toBeLessThanOrEqual(1);
        const yAt = (t: number) => {
          const after = frames.findIndex((frame) => frame.t >= t);
          if (after <= 0) return after === 0 ? frames[0]!.y : frames.at(-1)!.y;
          const [a, b] = [frames[after - 1]!, frames[after]!];
          return a.y + ((b.y - a.y) * (t - a.t)) / (b.t - a.t);
        };
        const steps = frames.map((frame) => Math.abs(yAt(frame.t + 1000 / 60) - frame.y));
        expect(Math.max(...steps)).toBeLessThanOrEqual(glideStep(Math.abs(frames.at(-1)!.y - frames[0]!.y)) + 1);
        // A rail that already scrolled holds the band still.
        expect(before.scrolls).toBe(loaded === 90);
        if (before.scrolls) expect(Math.abs(frames.at(-1)!.y - before.y)).toBeLessThanOrEqual(1);
        await page.close();
      }
    });

    // Leo, 2026-10-22: "it wouldn't show the highlighted bottom text where I was scrolling at the
    // bottom ... It didn't show the bottom bits being highlighted." The rail sits inside the
    // transcript, whose mask fades rows out under its top and above its foot; in a short window the
    // rail filled the view less 8 px each end, so its first and last lit ticks drew inside those fades.
    test("in a short window every lit tick stays clear of the transcript's faded edges, at any offset", async () => {
      const page = await open(turns(0, COUNT), 0, COUNT, 420);
      const clipped = await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const probe = window as unknown as { __still(frames?: number): Promise<void> };
        const px = (name: string) => Number.parseFloat(getComputedStyle(scroller).getPropertyValue(name)) || 0;
        const end = scroller.scrollHeight - scroller.clientHeight;
        const found: string[] = [];
        for (const share of [0, 0.02, 0.1, 0.5, 0.9, 0.97, 0.99, 1]) {
          scroller.scrollTop = Math.round(end * share);
          await probe.__still();
          const view = scroller.getBoundingClientRect();
          // The mask's opaque band (conversation.css): below the top fade, above the foot's.
          const top = view.top + px("--acpmux-fade-top");
          const bottom = view.top + view.height - px("--acpmux-dock-space") - px("--acpmux-fade-bottom");
          for (const tick of document.querySelectorAll<HTMLElement>('.acpmux-minimap__tick[aria-current="true"]')) {
            const box = tick.getBoundingClientRect();
            if (box.top < top - 0.5 || box.bottom > bottom + 0.5)
              found.push(
                `${share}: tick ${tick.dataset.tick} at ${box.top - view.top}..${box.bottom - view.top} of ${top - view.top}..${bottom - view.top}`,
              );
          }
        }
        return found;
      });
      expect(clipped).toEqual([]);
      await page.close();
    });
  });
});
