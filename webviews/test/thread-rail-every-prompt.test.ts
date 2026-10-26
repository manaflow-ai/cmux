// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The thread rail shows every prompt of the chat, not only the turns the transcript has loaded (Leo
// 2026-10-25: "if you haven't loaded in chats ... the session rails ... should be able to still,
// like, gradually load that stuff in"). A long chat opens on its tail; the pane then reads the
// chat's older turn-start records from acpmux, a page per idle callback, and the rail grows a
// tick for each prompt that opens a turn.
//
// Before: a 500-prompt chat opened on its last 50 turns drew 50 ticks until the reader scrolled up.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-every-prompt.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-every-prompt: skipping (run `bunx playwright install chromium`)");
    describe.skip("rail every prompt", () => test("chromium", () => {}));
    return;
  }
  const TURNS = 500;
  const TAIL = 50;
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser!, { turns: TURNS, running: false, tail: TAIL, readDelay: 300 });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  test("a 500-prompt chat opened on its last 50 turns shows 500 ticks, read a page at a time", async () => {
    const page = await pane!.open({ width: 1200, height: 800 });
    // The same window on every build: 3 s of painted frames and long tasks from the open on. acpmux
    // answers each older read 300 ms late (`readDelay`), so the prompts load inside the window.
    const load = await page.evaluate(async () => {
      const frames: number[] = [];
      const long: number[] = [];
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) long.push(entry.duration);
      });
      observer.observe({ type: "longtask" });
      const stop = window.cmuxAfterPaint((frame) => {
        frames.push(frame);
      });
      await new Promise((resolve) => setTimeout(resolve, 3000));
      stop();
      observer.disconnect();
      const gaps = frames.slice(1).map((frame, index) => frame - frames[index]!);
      return {
        frames: frames.length,
        worst: Math.max(0, ...gaps),
        longTasks: long.length,
        longMs: long.reduce((sum, ms) => sum + ms, 0),
        longest: Math.max(0, ...long),
        ticks: document.querySelectorAll(".acpmux-minimap__tick").length,
      };
    });
    console.log(
      `thread-rail-every-prompt: ${load.ticks} ticks; ${load.frames} frames in 3 s, worst gap ${load.worst.toFixed(1)} ms, ${load.longTasks} long tasks (${load.longMs.toFixed(0)} ms, longest ${load.longest.toFixed(0)} ms)`,
    );
    expect(load.ticks).toBe(TURNS);
    // No frame of the load blocks the page: each page is one idle callback's work.
    expect(load.worst).toBeLessThan(250);
    // Only the records that say where turns start, at most a page of them per read, never the turns'
    // replies: a prompt and a result per turn here.
    const promptReads = pane!.reads.filter(
      (read) => Array.isArray(read.kinds) && read.kinds.includes("user_message") && !read.kinds.includes("transcript"),
    );
    const backgroundReads = promptReads.filter((read) => read.limit > 16);
    expect(backgroundReads.length).toBeGreaterThan(0);
    expect(backgroundReads.length).toBeLessThanOrEqual(Math.ceil((2 * (TURNS - TAIL)) / 400) + 1);
    for (const read of backgroundReads) expect(read.limit).toBeLessThanOrEqual(400);
    // The transcript itself read nothing older: the rail's prompts came without its turns.
    expect(pane!.reads.filter((read) => read.kinds?.includes?.("transcript"))).toHaveLength(0);
    // The ticks are the chat's prompts in order, the first one Question 1.
    const labels = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")].map((tick) =>
        tick.getAttribute("aria-label"),
      ),
    );
    expect(labels[0]).toContain("Question 1");
    expect(labels[TURNS - TAIL]).toContain(`Question ${TURNS - TAIL + 1}`);
    expect(labels.at(-1)).toContain(`Question ${TURNS}`);
    await page.close();
  });
});
