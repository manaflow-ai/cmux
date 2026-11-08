// The session rail's hover sweep (Leo, 2026-10-31: "the left scroll rail still lags when i hover over
// a lot of it it needs to be faster"). A real pointer moves tick by tick down the rail's view and back
// up, one move per painted frame, as a hand sweeping the rail does. Each move is timed from its
// `pointerover` (a window capture listener, before React's) to the first painted frame that shows
// its tick lit and the card previewing its prompt. Per move it also records the React commits and
// their Profiler time; per sweep, the renderer's style recalcs, layouts and their time (CDP
// Performance metrics, Chromium only) divided by the moves. Production selectors only.
import type { CDPSession, Page } from "playwright";
import type { AdapterContext, AdapterRun } from "./measure";

declare global {
  interface Window {
    __railSweepSampler?: {
      arm(index: number): void;
      painted(index: number, timeoutMs: number): Promise<boolean>;
      stop(): RailSweepInPage;
    };
    __latencyReactActualMs?: number;
  }
}

type RailSweepMove = {
  index: number;
  inputAt: number | null;
  /** The first painted frame with the tick lit. */
  tickPaintAt: number | null;
  /** The first painted frame with the tick lit and the card showing its prompt. */
  paintAt: number | null;
  commits: number | null;
  reactMs: number | null;
};
type RailSweepInPage = { moves: RailSweepMove[]; frameGaps: number[] };

const LIST = ".acpmux-minimap__list";
const CARD = ".acpmux-minimap__card";
/** Past the rail card's leave grace and the hover group's warmth (ui/hoverIntent.ts). */
const COOL_MS = 800;
const METRICS = ["RecalcStyleCount", "RecalcStyleDuration", "LayoutCount", "LayoutDuration", "ScriptDuration"];

async function metrics(cdp: CDPSession | undefined): Promise<Record<string, number> | null> {
  if (!cdp) return null;
  const { metrics: all } = (await cdp.send("Performance.getMetrics")) as {
    metrics: Array<{ name: string; value: number }>;
  };
  return Object.fromEntries(all.filter((entry) => METRICS.includes(entry.name)).map((e) => [e.name, e.value]));
}

/** The ticks the sweep crosses: those drawn in the rail's view, clear of its fades, top to bottom. */
async function sweepTicks(page: Page, most: number) {
  if (await page.$("aside.acpmux-session-info")) {
    await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
    await page.waitForSelector("aside.acpmux-session-info", { state: "detached", timeout: 5_000 });
  }
  await page.waitForSelector(LIST, { state: "attached", timeout: 10_000 });
  await page.evaluate((selector) => {
    const transcript = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    transcript.scrollTop = transcript.scrollHeight;
    const list = document.querySelector<HTMLElement>(selector)!;
    list.scrollTop = list.scrollHeight;
  }, LIST);
  const size = page.viewportSize() ?? { width: 1280, height: 800 };
  await page.mouse.move(size.width - 4, 4);
  await page.waitForFunction((card) => !document.querySelector(card), CARD, { timeout: 5_000 });
  // fixed-wait: the hover group stays warm this long after a card hides; a cold first hover is measured
  await page.waitForTimeout(COOL_MS);
  return page.evaluate(
    ([selector, count]) => {
      const list = document.querySelector<HTMLElement>(selector)!;
      const box = list.getBoundingClientRect();
      const ticks = [...list.querySelectorAll<HTMLElement>("[data-tick]")].filter((tick) => {
        const rect = tick.getBoundingClientRect();
        return rect.height > 0 && rect.top >= box.top + 32 && rect.bottom <= box.bottom - 32;
      });
      return ticks.slice(-count).map((tick) => {
        const rect = tick.getBoundingClientRect();
        return { index: Number(tick.dataset.tick), x: rect.left + 8, y: rect.top + rect.height / 2 };
      });
    },
    [LIST, most] as const,
  );
}

/** One sweep down the rail's view and back up. `most` caps the ticks it crosses each way. */
export function measureRailSweep(most: number) {
  return async function measure(page: Page, context: AdapterContext): Promise<AdapterRun> {
    const stop = async () => {
      if (page.isClosed()) return;
      await page.evaluate(() => {
        window.__railSweepSampler?.stop();
        delete window.__railSweepSampler;
      });
    };
    context.onCleanup(stop);
    const ticks = await sweepTicks(page, most);
    if (ticks.length < 8) throw new Error(`only ${ticks.length} rail ticks to sweep`);
    const path = [...ticks, ...ticks.slice(0, -1).reverse()];
    const cdp = await page
      .context()
      .newCDPSession(page)
      .catch(() => undefined);
    await cdp?.send("Performance.enable", { timeDomain: "threadTicks" }).catch(() => undefined);
    await page.evaluate(
      ([list, card]) => {
        const moves: RailSweepMove[] = [];
        const frameGaps: number[] = [];
        let armed: RailSweepMove | undefined;
        let previous: number | undefined;
        let waiter: { index: number; resolve(ok: boolean): void } | undefined;
        const counters = () => ({ commits: window.__latencyReactCommits, ms: window.__latencyReactActualMs });
        let at = counters();
        const over = (event: PointerEvent) => {
          const tick = (event.target as Element | null)?.closest?.<HTMLElement>("[data-tick]");
          if (!armed || !tick || Number(tick.dataset.tick) !== armed.index || armed.inputAt !== null) return;
          armed.inputAt = performance.now();
          at = counters();
        };
        const lit = (index: number) =>
          document.querySelector(`${list} [data-tick="${index}"]`)?.getAttribute("data-tone") === "active";
        const previewed = (index: number) => {
          const label = document.querySelector(`${list} [data-tick="${index}"]`)?.getAttribute("aria-label") ?? "";
          const prompt = document.querySelector(`${card} .acpmux-minimap__prompt`)?.textContent ?? "";
          const box = document.querySelector(card)?.getBoundingClientRect();
          return !!prompt && label.includes(prompt) && !!box && box.width > 0 && box.height > 0;
        };
        const stopPaint = window.cmuxAfterPaint((frame) => {
          if (previous !== undefined) frameGaps.push(frame - previous);
          previous = frame;
          const move = armed;
          if (!move || move.inputAt === null || move.paintAt !== null) return true;
          const now = performance.now();
          if (move.tickPaintAt === null && lit(move.index)) move.tickPaintAt = now;
          if (move.tickPaintAt !== null && previewed(move.index)) {
            move.paintAt = now;
            const after = counters();
            move.commits =
              typeof after.commits === "number" && typeof at.commits === "number" ? after.commits - at.commits : null;
            move.reactMs = typeof after.ms === "number" && typeof at.ms === "number" ? after.ms - at.ms : null;
            if (waiter?.index === move.index) waiter.resolve(true);
            waiter = undefined;
          }
          return true;
        });
        window.addEventListener("pointerover", over, true);
        window.__railSweepSampler = {
          arm(index) {
            armed = { index, inputAt: null, tickPaintAt: null, paintAt: null, commits: null, reactMs: null };
            moves.push(armed);
          },
          painted(index, timeoutMs) {
            if (armed?.index === index && armed.paintAt !== null) return Promise.resolve(true);
            return new Promise((resolve) => {
              // fixed-wait: a deadline fails a move whose tick and card never paint; a painted move clears it at once
              const timer = setTimeout(() => resolve(false), timeoutMs);
              waiter = {
                index,
                resolve: (ok) => {
                  clearTimeout(timer);
                  resolve(ok);
                },
              };
            });
          },
          stop() {
            stopPaint();
            window.removeEventListener("pointerover", over, true);
            return { moves, frameGaps };
          },
        };
      },
      [LIST, CARD] as const,
    );
    const before = await metrics(cdp);
    let missed = 0;
    for (const tick of path) {
      if (context.signal.aborted) throw new Error("rail sweep cancelled");
      await page.evaluate((index) => window.__railSweepSampler!.arm(index), tick.index);
      await page.mouse.move(tick.x, tick.y);
      if (!(await page.evaluate((index) => window.__railSweepSampler!.painted(index, 1_000), tick.index))) missed += 1;
    }
    const after = await metrics(cdp);
    const result = await page.evaluate(() => {
      const value = window.__railSweepSampler!.stop();
      delete window.__railSweepSampler;
      return value;
    });
    await cdp?.detach().catch(() => undefined);
    const moves = result.moves.length;
    const per = (name: string, scale = 1) =>
      before && after ? ((after[name]! - before[name]!) * scale) / Math.max(1, moves) : null;
    const sweep = {
      moves,
      missed,
      ticks: ticks.length,
      recalcStylePerMove: per("RecalcStyleCount"),
      recalcStyleMsPerMove: per("RecalcStyleDuration", 1000),
      layoutPerMove: per("LayoutCount"),
      layoutMsPerMove: per("LayoutDuration", 1000),
      scriptMsPerMove: per("ScriptDuration", 1000),
    };
    return {
      status: missed ? "timeout" : "complete",
      ...(missed ? { reason: `${missed} of ${moves} sweep moves never painted their tick and card` } : {}),
      observations: result.moves.map((move) =>
        move.paintAt !== null && move.inputAt !== null
          ? {
              status: "painted" as const,
              latencyMs: move.paintAt - move.inputAt,
              inputAt: move.inputAt,
              targetPaintAt: move.paintAt,
              raw: { ...move, tickLatencyMs: move.tickPaintAt! - move.inputAt, sweep },
            }
          : {
              status: "timeout" as const,
              latencyMs: null,
              inputAt: null,
              targetPaintAt: null,
              raw: { ...move, sweep },
            },
      ),
      frameGaps: result.frameGaps.length ? result.frameGaps : null,
      longTasks: null,
      reactCommits: null,
      unsupportedReasons: {
        eventTiming: "hover sweep paint is a lab proxy, not EventTiming INP",
        trace: "CDP Performance metrics per sweep only; no full trace",
      },
    };
  };
}
