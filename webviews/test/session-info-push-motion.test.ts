// Lawrence: "animation at end is jumpy" (the chat's right-hand panel, Session Info, as it opens or
// closes). Pushing the chat aside (Settings Push always, session-info/SessionInfo.tsx `pushes`), the panel slid by `translate` while the chat laid out once: the chat narrowed on the
// first frame of the open, the panel still off to the right, and widened again only on the frame
// after the close ended, when the panel unmounted. The chat's column, its composer and the header's
// tools jumped the panel's width (328px in a 900px pane) right as the slide finished. Now the room
// the panel takes travels with it (sessionInfo.css: its right margin runs from minus its width), so on
// every frame of the open and the close the panel's left edge is the chat's right edge, and the frame
// the panel leaves is the chat's full width.
//
// Each transition is paused and seeked (Web Animations) to fixed points of the slide, with the motion
// tokens long enough that the presence's unmount timer never fires while a point is held. The page is
// the pane's dev entry with a stand-in acpmux (support/papercutChat.ts). Real Chromium and WebKit
// (the app's engine); CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/session-info-push-motion.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { sessionInfoPushAlways, papercutPane } from "./support/papercutChat";
import { sessionInfoPushes } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { SESSION_INFO_WIDTH } from "../src/agent-session/acpmux/session-info/sessionInfoState";

await requireBrowserLane("session-info-push-motion.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`session-info-push-motion: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("session info push motion", () => test("browsers", () => {}));
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

  /// Session Info on (Debug Settings `agent.inspector`, pushed with the header state) and closed,
  /// with the motion tokens at 4 s, so a seeked point holds.
  const ready = async (page: Page, push = true) => {
    await page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } })
        .cmuxAcpmuxBridge;
      bridge.applyHeaderState({ inspector: true, version: 2 });
      document.documentElement.style.setProperty("--agent-motion-in", "4000ms");
      document.documentElement.style.setProperty("--agent-motion-out", "4000ms");
    });
    // It takes a column only with Settings Push always (SessionInfo.tsx pushes).
    await sessionInfoPushAlways(page, push);
    const toggle = page.locator("button.acpmux-session-info-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    const panel = page.locator("aside.acpmux-session-info");
    if ((await panel.count()) > 0) {
      await toggle.click({ force: true });
      await panel.waitFor({ state: "detached", timeout: 15_000 });
    }
    return toggle;
  };

  /// At each point of the panel's running slide (a fraction of its transitions), the gap between the
  /// chat's right edge and the panel's left edge and the chat's width, in px; then lets the slide
  /// finish. `moving` names the properties its transitions animate.
  const slide = (page: Page, points: number[]) =>
    page.evaluate(async (fractions) => {
      const panel = document.querySelector<HTMLElement>("aside.acpmux-session-info")!;
      const chat = document.querySelector<HTMLElement>(".acpmux-main")!;
      const slides = panel.getAnimations();
      const gaps: number[] = [];
      const widths: number[] = [];
      for (const running of slides) running.pause();
      for (const fraction of fractions) {
        for (const running of slides) {
          const end = Number(running.effect?.getComputedTiming().endTime ?? 0);
          running.currentTime = fraction * end;
        }
        // Read after the seeked point has painted (support/paintedFrames.ts, which papercutPane installs).
        await window.cmuxPaintFrame();
        const box = chat.getBoundingClientRect();
        gaps.push(Math.round(Math.abs(panel.getBoundingClientRect().left - box.right)));
        widths.push(box.width);
      }
      for (const running of slides) running.finish();
      const moving = slides
        .map((running) => (running as Animation & { transitionProperty?: string }).transitionProperty ?? "")
        .sort();
      return { moving, gaps, widths };
    }, points);

  /// The chat's width now.
  const chatWidth = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-main")!.getBoundingClientRect().width);

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
        await page.locator('aside.acpmux-session-info[data-placement="push"]').waitFor({ timeout: 10_000 });
        const open = await slide(page, points);
        await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
        // The room the open panel takes from the chat.
        const room = shell - (await chatWidth(page));

        await toggle.click({ force: true });
        await page.locator('aside.acpmux-session-info[data-presence="leaving"]').waitFor({ timeout: 10_000 });
        const close = await slide(page, points);
        await page.locator("aside.acpmux-session-info").waitFor({ state: "detached", timeout: 15_000 });
        const after = await chatWidth(page);

        /// The share of the room the panel takes at each point.
        const taken = (widths: number[]) => widths.map((width) => (shell - width) / room);
        const rising = (values: number[]) => values.every((value, index) => index === 0 || value > values[index - 1]!);
        const opening = taken(open.widths);
        const closing = taken(close.widths);
        expect({
          room: room > 300,
          // The room itself moves (sessionInfo.css: the panel's right margin), not only the panel's paint.
          marginMoves: open.moving.includes("margin-right") && close.moving.includes("margin-right"),
          openGaps: open.gaps,
          closeGaps: close.gaps,
          // The chat gives up its room over the open and gets it back over the close, never at once.
          openTakes: rising(opening),
          closeGives: rising(closing.map((share) => -share)),
          openStartsWide: opening[0]! < 0.5,
          closeEndsWide: closing[closing.length - 1]! < 0.25,
          fullWidthAfter: Math.abs(after - shell) < 0.5,
        }).toEqual({
          room: true,
          marginMoves: true,
          openGaps: points.map(() => 0),
          closeGaps: points.map(() => 0),
          openTakes: true,
          closeGives: true,
          openStartsWide: true,
          closeEndsWide: true,
          fullWidthAfter: true,
        });
      } finally {
        await page.close();
      }
    });

  // Floating and pushing keep the same right margin (the inset), so a switch between the two (Settings
  // Push always) moves the panel to its new place at once, with no margin sliding after.
  // Since #31423 the default (Overlay) floats only where the pane's right gutter holds the panel; in a
  // narrower pane (900px) it pushes too, so Push always changes nothing there. The switch is made in a
  // pane wide enough that Overlay really floats (SessionInfo.tsx sessionInfoPushes, at the panel's
  // opening width), the same 1600px the layout-still and rail tests float in.
  const floatingPane = { width: 1600, height: 600 };
  test("the switch's pane floats with Overlay and pushes with Push always", () => {
    expect({
      overlay: sessionInfoPushes("overlay", floatingPane, SESSION_INFO_WIDTH.fallback),
      push: sessionInfoPushes("push", floatingPane, SESSION_INFO_WIDTH.fallback),
    }).toEqual({ overlay: false, push: true });
  });
  for (const name of browsers.keys())
    test(`${name}: a switch between floating and pushing starts no slide`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open(floatingPane);
      try {
        const toggle = await ready(page);
        await toggle.click({ force: true });
        await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
        await page.evaluate(() =>
          Promise.all(
            document
              .querySelector("aside.acpmux-session-info")!
              .getAnimations()
              .map((running) => running.finished.catch(() => undefined)),
          ),
        );
        const switched: string[] = [];
        for (const placement of ["overlay", "push"] as const) {
          await sessionInfoPushAlways(page, placement === "push");
          await page.locator(`aside.acpmux-session-info[data-placement="${placement}"]`).waitFor({ timeout: 10_000 });
          switched.push(
            ...(await page.evaluate(() => {
              const panel = document.querySelector("aside.acpmux-session-info")!;
              return panel
                .getAnimations()
                .map((running) => (running as Animation & { transitionProperty?: string }).transitionProperty ?? "");
            })),
          );
        }
        expect(switched).toEqual([]);
      } finally {
        await page.close();
      }
    });

  for (const name of browsers.keys())
    test(`${name}: floating Session Info leaves the header tools anchored`, async () => {
      current = browsers.get(name)!;
      // 1200px leaves a floating card close enough to the transcript column for the handoff shift;
      // at 1700px the shift is zero and the old stage selector would pass this assertion too.
      const page = await pane!.open({ width: 1200, height: 600 });
      try {
        const toggle = await ready(page, false);
        const before = await page.evaluate(
          () => document.querySelector<HTMLElement>(".acpmux-header-tools")!.getBoundingClientRect().right,
        );
        await toggle.click({ force: true });
        await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
        const after = await page.evaluate(
          () => document.querySelector<HTMLElement>(".acpmux-header-tools")!.getBoundingClientRect().right,
        );
        expect(Math.abs(after - before)).toBeLessThan(0.5);
      } finally {
        await page.close();
      }
    });
});
