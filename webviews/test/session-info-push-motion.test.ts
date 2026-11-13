// Lawrence: "animation at end is jumpy" (the chat's right-hand panel, Session Info, as it opens or
// closes). Pushing the chat aside, the panel slid by `translate` while the chat laid out once: the
// chat's column, its composer and the header's tools jumped the panel's width right as the slide
// finished. Now the chat keeps the pane's full width and only its column moves, on the chat's own
// transition (sessionInfo.css --acpmux-session-info-shift) as the panel slides in or out, so no frame of
// the open or the close jumps, and none lays the column under the panel.
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
import { sessionInfoPushes } from "../src/agent-session/acpmux/session-info/sessionInfoModel";
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

  /// Session Info on (Debug Settings `agent.sessionInfo`, pushed with the header state) and closed,
  /// with the motion tokens at 4 s, so a seeked point holds.
  const ready = async (page: Page, push = true) => {
    await page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } })
        .cmuxAcpmuxBridge;
      bridge.applyHeaderState({ inspector: true, version: 2 });
      document.documentElement.style.setProperty("--agent-motion-in", "4000ms");
      document.documentElement.style.setProperty("--agent-motion-out", "4000ms");
      // The push opens on the move step (sessionInfo.css).
      document.documentElement.style.setProperty("--agent-motion-move", "4000ms");
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

  /// At each point of the open's or the close's running slide (a fraction of its transitions: the
  /// panel's and the chat column's shift on the chat, sessionInfo.css --acpmux-session-info-shift), the
  /// chat's width, the column's left edge and width (the composer card's), and the panel's left edge, in
  /// px; then lets the slide finish. `moving` names what animates, the panel's and the chat's.
  const slide = (page: Page, points: number[]) =>
    page.evaluate(async (fractions) => {
      const panel = document.querySelector<HTMLElement>("aside.acpmux-session-info")!;
      const chat = document.querySelector<HTMLElement>(".acpmux-main")!;
      const column = () => document.querySelector<HTMLElement>(".acpmux-composer-box")!.getBoundingClientRect();
      const slides = [...panel.getAnimations(), ...chat.getAnimations()];
      const frames: { chat: number; left: number; right: number; width: number; panel: number }[] = [];
      for (const running of slides) running.pause();
      for (const fraction of fractions) {
        for (const running of slides) {
          const end = Number(running.effect?.getComputedTiming().endTime ?? 0);
          running.currentTime = fraction * end;
        }
        // Read after the seeked point has painted (support/paintedFrames.ts, which papercutPane installs).
        await window.cmuxPaintFrame();
        const box = column();
        frames.push({
          chat: chat.getBoundingClientRect().width,
          left: box.left,
          right: box.right,
          width: box.width,
          panel: panel.getBoundingClientRect().left,
        });
      }
      for (const running of slides) running.finish();
      const moving = slides
        .map((running) => (running as Animation & { transitionProperty?: string }).transitionProperty ?? "")
        .sort();
      return { moving, frames };
    }, points);

  /// The composer card's left edge now: where the chat's column sits.
  const columnLeft = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().left);

  const points = [0.03, 0.5, 0.85, 0.97];

  // Lucas, 2026-11-06: pushing keeps the chat the pane's full width (its scrollbar at the pane's edge,
  // right of the panel) and slides only its column, centered beside the panel, as the panel comes in.
  // On every frame of the open and the close the chat keeps its width, the column keeps its width (no
  // line rewraps) and never lies under the panel, and it moves steadily, never at once at either end.
  for (const name of browsers.keys())
    test(`${name}: pushing, the column slides with the panel, the chat keeps its width, and neither end jumps`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1200, height: 600 });
      try {
        const toggle = await ready(page);
        const shell = await page.evaluate(() => document.querySelector(".acpmux-shell")!.clientWidth);
        const rest = await columnLeft(page);

        await toggle.click({ force: true });
        await page.locator('aside.acpmux-session-info[data-placement="push"]').waitFor({ timeout: 10_000 });
        const open = await slide(page, points);
        await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
        // How far the open panel moved the column.
        const moved = rest - (await columnLeft(page));

        await toggle.click({ force: true });
        await page.locator('aside.acpmux-session-info[data-presence="leaving"]').waitFor({ timeout: 10_000 });
        const close = await slide(page, points);
        await page.locator("aside.acpmux-session-info").waitFor({ state: "detached", timeout: 15_000 });
        const after = await columnLeft(page);

        /// The share of the move the column has made at each point.
        const share = (frames: { left: number }[]) => frames.map((frame) => (rest - frame.left) / moved);
        const rising = (values: number[]) => values.every((value, index) => index === 0 || value > values[index - 1]!);
        const opening = share(open.frames);
        const closing = share(close.frames);
        const all = [...open.frames, ...close.frames];
        const width = all[0]!.width;
        expect({
          moved: moved > 100,
          // The column moves on the chat (sessionInfo.css), and the panel slides in and out.
          columnMoves:
            open.moving.includes("--acpmux-session-info-shift") && close.moving.includes("--acpmux-session-info-shift"),
          panelSlides: open.moving.includes("translate") && close.moving.includes("translate"),
          chatKeepsWidth: all.every((frame) => Math.abs(frame.chat - shell) < 0.5),
          columnKeepsWidth: all.every((frame) => Math.abs(frame.width - width) < 0.5),
          neverUnderPanel: all.every((frame) => frame.right <= frame.panel + 0.5),
          openTakes: rising(opening),
          closeGives: rising(closing.map((value) => -value)),
          openStartsNear: opening[0]! < 0.5,
          closeEndsNear: closing[closing.length - 1]! < 0.25,
          backAfter: Math.abs(after - rest) < 0.5,
        }).toEqual({
          moved: true,
          columnMoves: true,
          panelSlides: true,
          chatKeepsWidth: true,
          columnKeepsWidth: true,
          neverUnderPanel: true,
          openTakes: true,
          closeGives: true,
          openStartsNear: true,
          closeEndsNear: true,
          backAfter: true,
        });
      } finally {
        await page.close();
      }
    });

  // Floating and pushing keep the same right margin (the inset), so a switch between the two (Settings
  // Push always) moves the panel to its new place at once, with no slide after: not the panel's and not
  // the chat column's (sessionInfo.css slides it only as the panel comes in or leaves).
  // The default (Overlay) now pushes wherever the column fits beside the whole panel (Lucas,
  // 2026-11-06), and floats in the gutter only in a short pane (SessionInfo.tsx POPOVER_BELOW_HEIGHT,
  // 520px). The switch is made in a wide, short pane, where Overlay really floats and Push always's whole
  // room still keeps the transcript's column at its width (SessionInfo.tsx pushKeepsColumn).
  const floatingPane = { width: 1800, height: 500 };
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
              const chat = document.querySelector(".acpmux-main")!;
              return [...panel.getAnimations(), ...chat.getAnimations()].map(
                (running) => (running as Animation & { transitionProperty?: string }).transitionProperty ?? "",
              );
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
