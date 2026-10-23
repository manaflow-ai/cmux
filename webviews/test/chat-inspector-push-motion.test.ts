// Lawrence: "animation at end is jumpy" (the chat's right-hand panel, the Inspector, as it opens or
// closes). Pushing the chat aside (a pane whose gutter has no room for it, inspector/ChatInspector.tsx
// `pushes`), the panel slid by `translate` while the chat laid out once: the chat narrowed on the
// first frame of the open, the panel still off to the right, and widened again only on the frame
// after the close ended, when the panel unmounted. The chat's column, its composer and the header's
// tools jumped the panel's width (328px in a 900px pane) right as the slide finished. Now the room
// the panel takes travels with it (inspector.css: its right margin runs from minus its width), so on
// every frame of the open and the close the panel's left edge is the chat's right edge, and the frame
// the panel leaves is the chat's full width.
//
// Each transition is paused and seeked (Web Animations) to fixed points of the slide, with the motion
// tokens long enough that the presence's unmount timer never fires while a point is held. The page is
// the pane's dev entry with a stand-in acpmux (support/papercutChat.ts). Real Chromium and WebKit
// (the app's engine); CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/chat-inspector-push-motion.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-push-motion.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`chat-inspector-push-motion: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("inspector push motion", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, { turns: 4, running: false });
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// The Inspector on (Debug Settings `agent.inspector`, pushed with the header state) and closed,
  /// with the motion tokens at 4 s, so a seeked point holds.
  const ready = async (page: Page) => {
    await page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } })
        .cmuxAcpmuxBridge;
      bridge.applyHeaderState({ inspector: true, version: 2 });
      document.documentElement.style.setProperty("--agent-motion-in", "4000ms");
      document.documentElement.style.setProperty("--agent-motion-out", "4000ms");
    });
    const toggle = page.locator("button.acpmux-chat-inspector-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    const panel = page.locator("aside.acpmux-chat-inspector");
    if ((await panel.count()) > 0) {
      await toggle.click({ force: true });
      await panel.waitFor({ state: "detached", timeout: 15_000 });
    }
    return toggle;
  };

  /// At each point of the panel's running slide (a fraction of its transitions), the gap between the
  /// chat's right edge and the panel's left edge, in px; then lets the slide finish.
  const gaps = (page: Page, points: number[]) =>
    page.evaluate(async (fractions) => {
      const panel = document.querySelector<HTMLElement>("aside.acpmux-chat-inspector")!;
      const chat = document.querySelector<HTMLElement>(".acpmux-main")!;
      const slides = panel.getAnimations();
      const out: number[] = [];
      for (const slide of slides) slide.pause();
      for (const fraction of fractions) {
        for (const slide of slides) {
          const end = Number(slide.effect?.getComputedTiming().endTime ?? 0);
          slide.currentTime = fraction * end;
        }
        // Read after the seeked point has painted (support/paintedFrames.ts, which papercutPane installs).
        await window.cmuxPaintFrame();
        out.push(Math.round(Math.abs(panel.getBoundingClientRect().left - chat.getBoundingClientRect().right)));
      }
      for (const slide of slides) slide.finish();
      return { slides: slides.length, gaps: out };
    }, points);

  const points = [0.03, 0.5, 0.85, 0.97];

  for (const name of browsers.keys())
    test(`${name}: pushing, the chat narrows and widens with the panel, and neither end jumps`, async () => {
      current = browsers.get(name)!;
      // A 900px pane's gutter has no room for the 320px panel: it pushes.
      const page = await pane!.open({ width: 900, height: 600 });
      try {
        const toggle = await ready(page);
        const shell = await page.evaluate(() => document.querySelector(".acpmux-shell")!.clientWidth);

        await toggle.click({ force: true });
        await page.locator('aside.acpmux-chat-inspector[data-placement="push"]').waitFor({ timeout: 10_000 });
        const open = await gaps(page, points);
        await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').waitFor({ timeout: 10_000 });

        await toggle.click({ force: true });
        await page.locator('aside.acpmux-chat-inspector[data-presence="leaving"]').waitFor({ timeout: 10_000 });
        const close = await gaps(page, points);
        await page.locator("aside.acpmux-chat-inspector").waitFor({ state: "detached", timeout: 15_000 });
        const after = await page.evaluate(() => document.querySelector(".acpmux-main")!.getBoundingClientRect().width);

        expect({
          sliding: open.slides > 0 && close.slides > 0,
          open: open.gaps,
          close: close.gaps,
          fullWidthAfter: Math.abs(after - shell) < 0.5,
        }).toEqual({
          sliding: true,
          open: points.map(() => 0),
          close: points.map(() => 0),
          fullWidthAfter: true,
        });
      } finally {
        await page.close();
      }
    });
});
