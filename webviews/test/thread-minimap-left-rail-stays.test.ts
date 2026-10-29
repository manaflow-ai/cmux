// The thread rail (threadMinimap/ThreadMinimap.tsx) is never pushed aside by Session Info (Leo,
// 2026-10-25: "So the left rail thing, that still gets hidden. So, like, when that session rail is
// there, the session rail ends up pushing it to the side, and also when the left pane gets too narrow,
// the session rail still disappears. We can't have it disappear."). Session Info floats and moves the
// chat's column left only when both fit (inspector/ChatInspector.tsx inspectorChatShift); the rail
// follows the transcript's inset, preserving its full look while the gutter progressively shrinks.
// In a wide pane (1600), the pane where the column moves (1200), a narrow window (800), the
// overlap breakpoint (780), and the narrowest usable pane (760), with Session Info closed, open,
// and pushing (Push always): the rail keeps one full-width look, hugs the transcript at a 4 px
// resting gap, overlaps only at the breakpoint, and hides only when the minimum usable gutter is gone.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-left-rail-stays.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("thread-minimap-left-rail-stays.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`thread-minimap-left-rail-stays: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("left rail stays", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    // Eight prompts: the rail shows from four (threadMinimap/model.ts MIN_PROMPTS).
    pane = await papercutPane(() => current!, { turns: 8, running: false });
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(() =>
      Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
    );
  const showToggle = async (page: Page) => {
    await page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
      ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
    );
    const toggle = page.locator("button.acpmux-chat-inspector-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    return toggle;
  };
  const closeInspector = async (page: Page) => {
    const toggle = await showToggle(page);
    if ((await page.locator("aside.acpmux-chat-inspector").count()) > 0) {
      await toggle.click({ force: true });
      await page.locator("aside.acpmux-chat-inspector").waitFor({ state: "detached", timeout: 5_000 });
    }
    await settle(page);
  };
  const openInspector = async (page: Page, push: boolean) => {
    if (push) await inspectorPushAlways(page);
    const toggle = await showToggle(page);
    if ((await page.locator("aside.acpmux-chat-inspector").count()) === 0) await toggle.click({ force: true });
    await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').waitFor({ timeout: 10_000 });
    await settle(page);
  };
  /// Where the rail draws, against the pane and the transcript's column (its rows' left edge).
  const rail = (page: Page) =>
    page.evaluate(() => {
      const nav = document.querySelector(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
      const shell = document.querySelector(".acpmux-shell")!.getBoundingClientRect();
      const scroller = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
      const rows = [...document.querySelectorAll(".acpmux-row")].map((row) => row.getBoundingClientRect().left);
      const column = Math.min(...rows);
      if (!nav) return { shown: false as const };
      const box = nav.getBoundingClientRect();
      // A tick's resting bar, as drawn.
      const bar = nav.querySelector(".acpmux-minimap__bar")!.getBoundingClientRect();
      return {
        shown: true as const,
        scrollbarPinned: Math.abs(scroller.right - shell.right) < 1,
        left: Math.round(box.left),
        insidePane: box.left >= shell.left - 0.5 && box.right <= shell.right + 0.5 && bar.width > 0,
        clearOfColumn: box.right <= column + 0.5,
        distance: Math.round((column - box.right) * 10) / 10,
      };
    });

  for (const name of browsers.keys())
    for (const width of [1600, 1200, 1084, 800, 780, 760])
      test(`${name}: in a ${width}px pane the rail hugs the text until it runs out of room`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          const placed = { shown: true, scrollbarPinned: true, insidePane: true, clearOfColumn: true, distance: 4 };
          await closeInspector(page);
          const closed = await rail(page);
          await openInspector(page, false);
          const open = await rail(page);
          if (width === 1084 && process.env.RAIL_GUTTER_SCREENSHOT) {
            await page.screenshot({ path: process.env.RAIL_GUTTER_SCREENSHOT });
          }
          // Push always narrows the chat to the pane less the panel; the rail keeps its own small gutter
          // and is hidden only once that gutter cannot provide the allowed overlap.
          await closeInspector(page);
          await openInspector(page, true);
          const pushed = await rail(page);
          const where = ({ left: _left, ...rest }: { left?: number; shown: boolean }) => rest;
          // The transcript column's inset steps at the layout breakpoints. The rail keeps
          // its full 36px look and only overlaps at the 780px breakpoint; Push always
          // can consume the remaining gutter at 800px and below.
          const expected =
            width <= 760
              ? { shown: false }
              : {
                  ...placed,
                  clearOfColumn: width >= 800,
                  distance: width >= 800 ? 4 : -6,
                };
          const pushedExpected = width <= 1084 ? { shown: false } : { ...expected, scrollbarPinned: false };
          const openExpected = width === 1084 ? { ...placed, clearOfColumn: false, distance: -8 } : expected;
          expect({ closed: where(closed), open: where(open), pushed: where(pushed) }).toEqual({
            closed: expected,
            open: openExpected,
            pushed: pushedExpected,
          });
        } finally {
          await page.close();
        }
      });
  for (const name of browsers.keys())
    for (const width of [1200, 1084])
      test(`${name}: an open card follows its rail on every painted inspector and resize frame at ${width}px`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          await closeInspector(page);
          await page.locator(".acpmux-minimap__tick").first().focus();
          const card = page.locator(".acpmux-minimap__card");
          await card.waitFor({ state: "visible" });
          // Keep this same preview open while the Inspector changes independently of pointer/focus.
          await card.locator(".acpmux-minimap__bookmark").focus();
          await page.evaluate(() => {
            const samples: { rail: number; card: number | null }[] = [];
            const stop = window.cmuxAfterPaint(() => {
              const rail = document.querySelector(".acpmux-minimap__rail")!.getBoundingClientRect();
              const card = document.querySelector(".acpmux-minimap__card")?.getBoundingClientRect();
              samples.push({ rail: rail.right, card: card?.left ?? null });
              return true;
            });
            Object.assign(window, { railCardFrames: { samples, stop } });
          });
          const toggle = () =>
            page.locator("button.acpmux-chat-inspector-toggle").evaluate((node) => (node as HTMLElement).click());
          for (const open of [true, false, true]) {
            await toggle();
            await page.locator("aside.acpmux-chat-inspector").waitFor({ state: open ? "visible" : "detached" });
            await settle(page);
            await page.evaluate(() => window.cmuxPaintFrame());
          }
          for (const next of [1600, 1084, 1200]) {
            await page.setViewportSize({ width: next, height: 700 });
            await page.waitForFunction((next) => document.querySelector(".acpmux-shell")!.clientWidth === next, next);
            await settle(page);
            await page.evaluate(() => window.cmuxPaintFrame());
          }
          const samples = await page.evaluate(() => {
            const trace = (
              window as unknown as {
                railCardFrames: { samples: { rail: number; card: number | null }[]; stop(): void };
              }
            ).railCardFrames;
            trace.stop();
            return trace.samples;
          });
          expect(samples.length).toBeGreaterThan(0);
          expect(new Set(samples.map((sample) => Math.round(sample.rail))).size).toBeGreaterThan(2);
          expect(samples.filter((sample) => sample.card === null || Math.abs(sample.card - sample.rail) > 1)).toEqual(
            [],
          );
          if (process.env.RAIL_CARD_SCREENSHOT) await page.screenshot({ path: process.env.RAIL_CARD_SCREENSHOT });
        } finally {
          await page.close();
        }
      });
});
