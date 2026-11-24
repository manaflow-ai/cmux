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

/// web-vitals CLS: the largest session window's sum (a window ends after a 1 s gap or at 5 s).
export function clsOf(shifts: readonly { at: number; value: number; recent: boolean }[]): number {
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

await requireBrowserLane("agent-pane-thinking-cls.test.ts", async () => {
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
    pane = await papercutPane(() => browser, { turns: 12, running: false, production: {} });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const thought = (text: string) => update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
  const reply = (text: string) =>
    update({ sessionUpdate: "agent_message_chunk", messageId: "m-think", content: { type: "text", text } });

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
  const painted: { step: string; score: number; moves: string[]; stray: string[] }[] = [];
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
          const next = () => (--left <= 0 ? done() : requestAnimationFrame(next));
          requestAnimationFrame(next);
        }),
      count,
    );

  let liveUnderThought: number | null = null;
  let replyUnderThought: number | null = null;
  async function playThinkingTurn(page: Page, turn: number) {
    await step(page, "send");
    pane.record("user_message", { text: `Think about ${turn}`, promptId: `p-think-${turn}` });
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
    }
    await frames(page, 20);
    // Where the live line's words sit under the thought, then where the reply's first line lands.
    const under = (id: string) =>
      page.evaluate((id) => {
        const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")];
        const thought = rows.filter((row) => row.querySelector(".cv-thought")).at(-1);
        const target =
          id === "reply"
            ? rows.filter((row) => row.dataset.rowId?.startsWith("assistant")).at(-1)
            : rows.find((row) => row.dataset.rowId === id);
        if (!thought || !target) return null;
        return target.getBoundingClientRect().top - thought.getBoundingClientRect().bottom;
      }, id);
    liveUnderThought = await under("thinking-live");
    await step(page, "answer starts");
    pane.record("agent_message_chunk", reply(`Answer ${turn}: `), "in");
    await page.waitForFunction(
      (text) =>
        [...document.querySelectorAll<HTMLElement>('[data-row-id^="assistant"]')].at(-1)?.textContent?.includes(text),
      `Answer ${turn}:`,
    );
    replyUnderThought = await under("reply");
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
  }

  test("a turn that thinks, then answers, shifts nothing in view (CLS under 0.001)", async () => {
    const page = await pane.open({ width: 900, height: 700 });
    await installBoxTracker(page);
    await observe(page);
    await frames(page, 30);
    await playThinkingTurn(page, 1);
    const shifts = (await page.evaluate(() => (window as any).__cls)) as Shift[];
    const cls = clsOf(shifts);
    const bySteps = new Map<string, number>();
    for (const shift of shifts)
      if (!shift.recent) bySteps.set(shift.step, (bySteps.get(shift.step) ?? 0) + shift.value);
    console.log(
      `THINKING_CLS ${JSON.stringify({ cls: Number(cls.toFixed(5)), shifts: shifts.length, bySteps: Object.fromEntries(bySteps) })}`,
    );
    if (TRACE)
      for (const shift of shifts)
        console.log(
          `  ${shift.at.toFixed(0)} ${shift.step} ${shift.value.toFixed(5)} ${shift.sources.map((source) => `${source.node} ${source.from.join(",")} -> ${source.to.join(",")}`).join(" | ")}`,
        );
    const boxScore = painted.reduce((sum, entry) => sum + entry.score, 0);
    const stray = painted.flatMap((entry) => entry.stray.map((move) => `${entry.step}: ${move}`));
    console.log(
      `THINKING_BOX_CLS ${JSON.stringify({ score: Number(boxScore.toFixed(5)), bySteps: Object.fromEntries(painted.map((entry) => [entry.step, Number(entry.score.toFixed(5))])), stray: stray.length, liveUnderThought, replyUnderThought })}`,
    );
    if (TRACE)
      for (const entry of painted)
        if (entry.moves.length || entry.stray.length)
          console.log(`  box ${entry.step}: moves ${entry.moves.join(" | ")} stray ${entry.stray.join(" | ")}`);
    await page.close();
    expect(cls).toBeLessThan(0.001);
    // The reply takes the live line's place under the thought: the gap after the thought is its final one from the
    // thought's first frame, so the follow moves the rows over it by the reply's own line and no more.
    expect(liveUnderThought).not.toBeNull();
    expect(replyUnderThought).not.toBeNull();
    expect(Math.abs(replyUnderThought! - liveUnderThought!)).toBeLessThan(1);
    // Every painted move the follow does not explain.
    expect(stray).toEqual([]);
  });
});
