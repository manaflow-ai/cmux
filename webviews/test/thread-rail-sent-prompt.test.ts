// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The prompt the reader sends shows on the thread rail at once, at the bottom (Leo 2026-10-25: "my
// latest prompt that I sent in ... should be able to go in at the bottom as well"): its tick draws in
// the same painted frame as its bubble in the transcript, lit and in view at the rail's end, before
// any reply. When acpmux's echo of it replaces the pane's own row, the tick stays the same element:
// no second tick, no tick that goes and comes back (model.ts turnKey), and so through a reconnect
// that reads the chat's log again.
//
// Before: the echo keyed a new tick (the row id went from `local-<promptId>` to `user-<seq>`), so the
// rail dropped the sent prompt's tick and mounted another in its place.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-sent-prompt.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-sent-prompt: skipping (run `bunx playwright install chromium`)");
    describe.skip("rail sent prompt", () => test("chromium", () => {}));
    return;
  }
  const TURNS = 100;
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser!, { turns: TURNS, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  type Frame = { bubble: boolean; ticks: number; inView: boolean; tone?: string; label?: string; same?: boolean };

  test("a sent prompt's tick draws with its bubble, at the bottom, and the echo keeps it", async () => {
    const page = await pane!.open({ width: 1200, height: 800 });
    // The rail draws only the ticks in its view (tickWindow.ts); each tick's list item names how many
    // prompts there are.
    expect(await page.locator(".acpmux-minimap__entry").first().getAttribute("aria-setsize")).toBe(String(TURNS));
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("Brand new prompt");
    // Every painted frame from here: whether the bubble shows, the rail's ticks, and whether its last
    // tick is the one first drawn for the send.
    await page.evaluate(() => {
      const scope = window as unknown as { railFrames: Frame[]; stopRail: () => void; sentTick?: Element };
      scope.railFrames = [];
      scope.stopRail = window.cmuxAfterPaint(() => {
        const bubble = [...document.querySelectorAll(".cv-user__bubble")].some(
          (node) => node.textContent?.trim() === "Brand new prompt",
        );
        const last = [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")].at(-1);
        const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")?.getBoundingClientRect();
        const box = last?.getBoundingClientRect();
        const label = last?.getAttribute("aria-label") ?? undefined;
        if (bubble && !scope.sentTick && label?.includes("Brand new prompt")) scope.sentTick = last;
        scope.railFrames.push({
          bubble,
          ticks: Number(last?.closest("li")?.getAttribute("aria-setsize") ?? 0),
          inView: !!(list && box && box.top >= list.top - 0.5 && box.bottom <= list.bottom + 0.5),
          tone: last?.dataset.tone,
          label,
          same: scope.sentTick ? scope.sentTick === last : undefined,
        });
      });
    });
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => (window as unknown as { sentTick?: Element }).sentTick !== undefined, undefined, {
      timeout: 10_000,
    });
    // acpmux's echo of the send, then the turn starting: the row becomes acpmux's own.
    const sent = pane!.prompts.at(-1)!;
    const promptId = sent._meta?.acpmux?.promptId;
    expect(typeof promptId).toBe("string");
    pane!.record("user_message", { text: "Brand new prompt", promptId, turnId: `turn-${promptId}` });
    pane!.record("turn_started", {});
    await page.waitForFunction(
      (expectedPromptId) =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-row")].some(
          (row) => row.dataset.rowId === `local-${expectedPromptId}` && row.textContent?.includes("Brand new prompt"),
        ),
      promptId,
      { timeout: 10_000 },
    );
    // A few more frames after the echo.
    for (let n = 0; n < 6; n++) await page.evaluate(() => window.cmuxPaintFrame());
    // The connection drops and comes back: the page reads the chat's log again, where the prompt is
    // acpmux's record alone (no send of this page's behind it).
    const attaches = pane!.methods.filter((method) => method === "_acpmux/attach").length;
    const reattached = pane!.sent("_acpmux/attach", attaches);
    pane!.drop();
    await reattached;
    expect(pane!.methods.filter((method) => method === "_acpmux/attach").length).toBeGreaterThan(attaches);
    for (let n = 0; n < 20; n++) await page.evaluate(() => window.cmuxPaintFrame());
    const frames = await page.evaluate(() => {
      const scope = window as unknown as { railFrames: Frame[]; stopRail: () => void };
      scope.stopRail();
      return scope.railFrames;
    });
    const first = frames.findIndex((frame) => frame.bubble);
    expect(first).toBeGreaterThanOrEqual(0);
    // The frame that first paints the bubble paints its tick: the last, in view, lit.
    expect(frames[first]).toMatchObject({ ticks: TURNS + 1, inView: true, tone: "current" });
    expect(frames[first]!.label).toContain("Brand new prompt");
    // From then on, through the echo: one tick for it, the same element, never another.
    for (const frame of frames.slice(first)) {
      expect(frame.ticks).toBe(TURNS + 1);
      expect(frame.label).toContain("Brand new prompt");
      expect(frame.same).toBe(true);
    }
    await page.close();
  });
});
