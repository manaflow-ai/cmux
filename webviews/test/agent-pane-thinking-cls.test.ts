// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts, thoughts and replies, not shipped UI.
// A turn that thinks and then answers shifts nothing in view (Leo, 2026-11-24: "the extra spacing after
// thinking added more layout shifts ... what's the layout-shift number before and after?").
//
// Cumulative layout shift as web-vitals counts it: the Layout Instability API's `layout-shift` entries
// (each frame's impact fraction times distance fraction of what moved in the viewport, scroll and
// transforms excluded), summed per session window (1 s gap, 5 s cap), the largest window reported.
// The page is the pane's dev entry and a stand-in acpmux (support/papercutChat.ts), real Chromium. One
// turn plays: the prompt, a thought streamed in deltas, the reply streamed after it, the turn's end.
//
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-thinking-cls.test.ts
// THINKING_CLS_TRACE=1 prints each shift's step, value and sources, and each step's painted moves.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import type { BoxShift } from "../src/gallery/shift";
import { installBoxTracker } from "./support/boxTrackerPage";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Shift = {
  at: number;
  value: number;
  recent: boolean;
  step: string;
  sources: { node: string; from: number[]; to: number[] }[];
};

await requireBrowserLane("agent-pane-thinking-cls.test.ts", async () => {
  /// web-vitals CLS: the largest session window's sum (a window ends after a 1 s gap or at 5 s).
  function clsOf(shifts: readonly { at: number; value: number; recent: boolean }[]): number {
    let best = 0;
    let sum = 0;
    let first = -Infinity;
    let last = -Infinity;
    for (const shift of shifts) {
      if (shift.recent) continue;
      if (shift.at - last > 1000 || shift.at - first > 5000) {
        sum = 0;
        first = shift.at;
      }
      sum += shift.value;
      last = shift.at;
      best = Math.max(best, sum);
    }
    return best;
  }

  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-thinking-cls: skipping (run `bunx playwright install chromium`)");
    describe.skip("thinking CLS", () => test("chromium", () => {}));
    return;
  }
  const TRACE = process.env.THINKING_CLS_TRACE === "1";
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 12,
      running: false,
      production: {},
    });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const thought = (text: string) =>
    update({
      sessionUpdate: "agent_thought_chunk",
      content: { type: "text", text },
    });
  const reply = (text: string) =>
    update({
      sessionUpdate: "agent_message_chunk",
      messageId: "m-think",
      content: { type: "text", text },
    });

  /// Records every layout shift from now on, each tagged with the step the page was told it is in.
  async function observe(page: Page) {
    await page.evaluate(() => {
      const w = window as any;
      w.__clsStep = "open";
      w.__cls = [];
      const describe = (node: Node | null) => {
        const element = node instanceof Element ? node : node?.parentElement;
        if (!element) return "?";
        const row = element.closest<HTMLElement>("[data-row-id]");
        const own = `${element.tagName.toLowerCase()}${element.className && typeof element.className === "string" ? "." + element.className.trim().split(/\s+/).slice(0, 2).join(".") : ""}`;
        return row ? `${row.dataset.rowId} ${own}` : own;
      };
      const box = (rect: DOMRectReadOnly) => [rect.x, rect.y, rect.width, rect.height].map((n) => Math.round(n));
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as any[])
          w.__cls.push({
            at: entry.startTime,
            value: entry.value,
            recent: entry.hadRecentInput,
            step: w.__clsStep,
            sources: (entry.sources ?? []).map((source: any) => ({
              node: describe(source.node),
              from: box(source.previousRect),
              to: box(source.currentRect),
            })),
          });
      }).observe({ type: "layout-shift", buffered: false });
    });
  }
  // The painted boxes too (src/gallery/shift.ts): the API leaves out moves made by transforms and
  // scrolling, so a row the follow carries is not in it; the box score counts every visible move the
  // shared follow does not explain, per step.
  const painted: {
    step: string;
    score: number;
    moves: string[];
    stray: string[];
  }[] = [];
  let tracking: string | undefined;
  async function endStep(page: Page) {
    if (!tracking) return;
    const shift: BoxShift = await page.evaluate(() => window.cmuxBoxTracker!.stop());
    painted.push({
      step: tracking,
      score: shift.score,
      moves: shift.moves.map((move) => `${move.label} ${move.dx},${move.dy}@${move.frame}`),
      stray: (shift.follow?.stray ?? []).map(
        (move) => `${move.label} ${move.dy}px (follow ${move.follow})@${move.frame}`,
      ),
    });
    tracking = undefined;
  }
  async function step(page: Page, name: string) {
    await endStep(page);
    await page.evaluate((name) => ((window as any).__clsStep = name), name);
    await page.evaluate(() => window.cmuxBoxTracker!.start());
    tracking = name;
  }
  const frames = (page: Page, count: number) =>
    page.evaluate(
      (count) =>
        new Promise<void>((done) => {
          let left = count;
          // raf-read: reads nothing; only counts frames so the box tracker samples between steps.
          const next = () => (--left <= 0 ? done() : requestAnimationFrame(next));
          requestAnimationFrame(next);
        }),
      count,
    );

  type Run = {
    live: number | null;
    reply: number | null;
    anchor: string;
    rows: string;
  };
  /// One turn: the prompt, a thought in deltas, the reply in deltas, the end. `opened` clicks the running turn's
  /// "Working for" open mid-thought, so the thought draws over the live line; closed (the default since #51082) the
  /// live line sits under "Working for" with no thought drawn.
  async function playThinkingTurn(page: Page, turn: number, opened: boolean): Promise<Run> {
    painted.length = 0;
    await step(page, "send");
    pane.record("user_message", {
      text: `Think about ${turn}`,
      promptId: `p-think-${turn}`,
    });
    pane.record("turn_started", {});
    await frames(page, 20);
    await step(page, "thinking");
    for (let n = 0; n < 24; n++) {
      pane.record(
        "agent_thought_chunk",
        thought(`Weighing the retry path, step ${n}, and what the jitter does. `),
        "in",
      );
      await frames(page, 3);
      if (opened && n === 4) {
        await endStep(page);
        await page.locator(".cv-worked__toggle").last().click();
        await frames(page, 20);
        await step(page, "thinking");
      }
    }
    await frames(page, 20);
    // The row the live line and then the reply sit under: the thought when it is drawn, else "Working for".
    // Where the live line's top sits under it, then where the reply's top lands.
    const under = (which: "live" | "reply") =>
      page.evaluate((which) => {
        const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")];
        const anchor =
          rows.filter((row) => row.querySelector(".cv-thought")).at(-1) ??
          rows.filter((row) => row.dataset.rowId?.startsWith("worked-")).at(-1);
        const target =
          which === "reply"
            ? rows.filter((row) => row.dataset.rowId?.startsWith("assistant")).at(-1)
            : rows.filter((row) => row.classList.contains("acpmux-row--below")).at(-1);
        if (!anchor || !target)
          return {
            gap: null,
            anchor: anchor?.dataset.rowId ?? "-",
            rows: rows
              .slice(-4)
              .map((row) => `${row.dataset.rowId}:${row.className}`)
              .join(" "),
          };
        return {
          gap: target.getBoundingClientRect().top - anchor.getBoundingClientRect().bottom,
          anchor: anchor.dataset.rowId ?? "-",
          rows: "",
        };
      }, which);
    const live = await under("live");
    await step(page, "answer starts");
    pane.record("agent_message_chunk", reply(`Answer ${turn}: `), "in");
    await page.waitForFunction(
      (text) =>
        [...document.querySelectorAll<HTMLElement>('[data-row-id^="assistant"]')].at(-1)?.textContent?.includes(text),
      `Answer ${turn}:`,
    );
    const answer = await under("reply");
    await frames(page, 20);
    await step(page, "answer streams");
    for (let n = 0; n < 24; n++) {
      pane.record("agent_message_chunk", reply(`the checks on the merged head are green, part ${n}. `), "in");
      await frames(page, 3);
    }
    await frames(page, 20);
    await step(page, "turn ends");
    pane.record("turn_result", { status: "completed" });
    await frames(page, 90);
    await endStep(page);
    return {
      live: live.gap,
      reply: answer.gap,
      anchor: `${live.anchor}/${answer.anchor}`,
      rows: live.rows + answer.rows,
    };
  }

  for (const opened of [false, true])
    test(`a turn that thinks, then answers, shifts nothing in view, "Working for" ${opened ? "opened" : "closed"} (CLS under 0.001)`, async () => {
      const page = await pane.open({ width: 900, height: 700 });
      await installBoxTracker(page);
      await observe(page);
      await frames(page, 30);
      const run = await playThinkingTurn(page, opened ? 2 : 1, opened);
      const shifts = (await page.evaluate(() => (window as any).__cls)) as Shift[];
      const cls = clsOf(shifts);
      const bySteps = new Map<string, number>();
      for (const shift of shifts)
        if (!shift.recent) bySteps.set(shift.step, (bySteps.get(shift.step) ?? 0) + shift.value);
      const view = opened ? "opened" : "closed";
      console.log(
        `THINKING_CLS ${view} ${JSON.stringify({ cls: Number(cls.toFixed(5)), shifts: shifts.length, bySteps: Object.fromEntries(bySteps) })}`,
      );
      if (TRACE)
        for (const shift of shifts)
          console.log(
            `  ${shift.at.toFixed(0)} ${shift.step} ${shift.value.toFixed(5)} ${shift.sources.map((source) => `${source.node} ${source.from.join(",")} -> ${source.to.join(",")}`).join(" | ")}`,
          );
      const boxScore = painted.reduce((sum, entry) => sum + entry.score, 0);
      const stray = painted.flatMap((entry) => entry.stray.map((move) => `${entry.step}: ${move}`));
      const bySteps2: Record<string, number> = {};
      for (const entry of painted)
        bySteps2[entry.step] = Number(((bySteps2[entry.step] ?? 0) + entry.score).toFixed(5));
      console.log(
        `THINKING_BOX_CLS ${view} ${JSON.stringify({ score: Number(boxScore.toFixed(5)), bySteps: bySteps2, stray: stray.length, ...run })}`,
      );
      if (TRACE)
        for (const entry of painted)
          if (entry.moves.length || entry.stray.length)
            console.log(`  box ${entry.step}: moves ${entry.moves.join(" | ")} stray ${entry.stray.join(" | ")}`);
      await page.close();
      if (!opened) expect(cls).toBeLessThan(0.001);
      // Opened, the click leaves the follow (the reader opened what they read), so the reply grows down the view and
      // the live line under it moves down with it: that line is the only thing that moves.
      else
        expect(
          shifts
            .filter(
              (shift) => !shift.recent && shift.sources.some((source) => !source.node.startsWith("thinking-live")),
            )
            .map((shift) => `${shift.step} ${shift.value.toFixed(5)}`)
            .filter((line) => !line.endsWith(" 0.00001") && !line.endsWith(" 0.00000")),
        ).toEqual([]);
      // The reply takes the live line's place under the row over it (the thought, or "Working for" closed): the gap
      // there is its final one from the first frame, so the follow moves the rows over it by the reply's own line.
      expect(run.live).not.toBeNull();
      expect(run.reply).not.toBeNull();
      expect(Math.abs(run.reply! - run.live!)).toBeLessThan(1.5);
      // Every painted move the follow does not explain.
      expect(stray).toEqual([]);
    });
});
