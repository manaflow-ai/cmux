// l10n-allow-file: test fixture prompts and a streamed reply's stand-in text, not shipped UI.
// A trackpad scroll down at the bottom of a followed chat leaves it followed (Leo, 2026-11-18: "did we
// fix this scroll bounce at the bottom yet?", then "there are some more animations here"). On macOS a
// scroll down past a scroller's end stretches it (elastic overscroll) and springs it back: WebKit
// reports the stretch in `scrollTop`, past the scroller's end, and the spring back is a run of scroll
// events whose offset falls back to the end, inside the reader's input hold. Each of those read as
// the reader scrolling up (VirtualTranscript `handleScroll`, `recentUp`), so the view stopped
// following at its own end: the reply streaming on grew under the composer behind Jump to latest
// until the next wheel event at the end armed following again ("reader-end").
// Chromium never overscrolls an element, so the stretch is drawn here as WebKit reports it: the
// scroller's `scrollTop` reads the stretch over the real offset while a scroll event fires each
// frame. Real Chromium against the pane's dev entry (support/papercutChat.ts). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-bottom-rebound-follow.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("agent-pane-bottom-rebound-follow.test.ts", async () => {
  /// A spring back from a scroll down past the end, px past it per frame: the stretch the trackpad's
  /// last events pulled, then the rebound to the end.
  const STRETCH = [6, 14, 22, 28, 30, 26, 19, 12, 7, 3, 1, 0];

  /// Draws the stretch as WebKit reports it, one scroll event a frame, then lets the real offset show.
  const rebound = (page: Page) =>
    page.evaluate(async (stretch) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const real = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
      let past = 0;
      Object.defineProperty(scroller, "scrollTop", {
        configurable: true,
        get: () => (real.get!.call(scroller) as number) + past,
        set: (value: number) => real.set!.call(scroller, value),
      });
      const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      try {
        for (const px of stretch) {
          await frame();
          past = px;
          scroller.dispatchEvent(new Event("scroll"));
        }
        await frame();
      } finally {
        delete (scroller as { scrollTop?: number }).scrollTop;
      }
    }, STRETCH);

  /// Where the view sits against its end, and whether Jump to latest shows, read each frame for `ms`.
  const watch = (page: Page, ms: number) =>
    page.evaluate(async (ms) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let worst = 0;
      let jump = false;
      const start = performance.now();
      while (performance.now() - start < ms) {
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        worst = Math.max(worst, scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
        jump ||= !!document.querySelector(".acpmux-jump-latest:not(.acpmux-jump-up)[data-shown]");
      }
      return {
        worst: Math.round(worst),
        jump,
        end: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
      };
    }, ms);

  setDefaultTimeout(120_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: true, ready: ".acpmux-row" });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  /// The reader's scroll down at the bottom, with or without the stretch's spring back, then the
  /// running turn's reply streams on: a followed view keeps its latest line in view.
  const scrollDownAtEnd = async (springBack: boolean) => {
    const page = await pane.open({ width: 900, height: 700 });
    try {
      // fixed-wait: the open's own motion settles first, as agent-pane-ticking-bottom-still does; the
      // draw has no event for its last motion ending.
      await page.waitForTimeout(1500);
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(box.x + box.width * 0.8, box.y + box.height * 0.7);
      // The trackpad's scroll down at the end: the browser scrolls nothing, the stretch takes it.
      await page.mouse.wheel(0, 40);
      if (springBack) await rebound(page);
      pane.record(
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: {
              sessionUpdate: "agent_message_chunk",
              content: {
                type: "text",
                text: Array.from({ length: 24 }, (_, n) => `Check ${n + 1} passed in the suite.`).join("\n\n"),
              },
            },
          },
        },
        "in",
      );
      const result = await watch(page, 1500);
      console.log(springBack ? "rebound" : "no-rebound", JSON.stringify(result));
      expect(result.jump).toBe(false);
      expect(result.end).toBeLessThanOrEqual(2);
    } finally {
      await page.close();
    }
  };

  test("the spring back from a scroll down past the end keeps a streaming chat followed", () => scrollDownAtEnd(true));

  // The same scroll down with no stretch: what the spring back must not change.
  test("a scroll down at the end keeps a streaming chat followed", () => scrollDownAtEnd(false));
});
