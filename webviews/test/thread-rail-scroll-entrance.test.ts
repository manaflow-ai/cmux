// l10n-allow-file: fixture prompts and replies, not shipped UI.
// Scrolling existing history must not replay tick entrances. Pausing entrances at their first
// frame makes the formerly blank ticks observable without a wall-clock timing assertion.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-scroll-entrance.test.ts", async () => {
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 1200, running: false });
  }, 120_000);
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });
  test("existing ticks draw immediately when scrolled into view, including a return visit", async () => {
    const page = await pane.open({ width: 1280, height: 900 });
    try {
      await page.addStyleTag({ content: ".acpmux-minimap__bar { animation-play-state: paused !important; }" });
      for (const index of [300, 700, 300]) {
        const drawn = await page.locator(".acpmux-minimap__list").evaluate(
          (node, index) =>
            new Promise<{ opacity: number; width: number }>((resolve, reject) => {
              const start = performance.now();
              node.scrollTop = index * 10 - node.clientHeight / 2;
              window.cmuxAfterPaint(() => {
                const bar = node.querySelector<HTMLElement>(`[data-tick="${index}"] .acpmux-minimap__bar`);
                if (performance.now() - start > 10_000) {
                  reject(new Error("Tick did not mount"));
                  return false;
                }
                if (!bar) return true;
                resolve({ opacity: Number(getComputedStyle(bar).opacity), width: bar.getBoundingClientRect().width });
                return false;
              });
            }),
          index,
        );
        expect(drawn.opacity).toBeGreaterThanOrEqual(0.39);
        expect(drawn.width).toBeGreaterThanOrEqual(5.9);
      }
      // A truly new prompt still gets the same entrance; scrolling it away and back does not.
      pane.record("user_message", { text: "Question 1201" });
      const newest = page.locator('[data-tick="1200"] .acpmux-minimap__bar');
      await newest.waitFor({ state: "attached" });
      expect(
        await newest.evaluate((bar) =>
          bar
            .getAnimations()
            .some((animation) => (animation as CSSAnimation).animationName === "acpmux-minimap-tick-in"),
        ),
      ).toBe(true);
    } finally {
      await page.close();
    }
  }, 120_000);
});
