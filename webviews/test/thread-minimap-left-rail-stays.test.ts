// The thread rail (threadMinimap/ThreadMinimap.tsx) is pinned to the pane's left edge and never
// pushed aside by Session Info (Leo, 2026-10-25: "So the left rail thing, that still gets hidden. So, like, when that session rail is
// there, the session rail ends up pushing it to the side, and also when the left pane gets too narrow,
// the session rail still disappears. We can't have it disappear."). Session Info floats and never
// moves the chat's column (Leo, 2026-10-29: "it's not supposed to be a fucking sidebar that pushes the
// fucking layout"); the rail stays at its pane-edge inset, open or closed.
// In a wide pane (1600), a pane whose gutter cannot hold the panel (1200), a narrow window (800), the
// overlap breakpoint (780), and the narrowest usable pane (760), with Session Info closed, open,
// and pushing (Push always): the rail keeps one full-width look, uses its pane-edge spacing inset,
// and keeps a live edge strip when the text leaves no room.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-left-rail-stays.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { sessionInfoPushAlways, papercutPane } from "./support/papercutChat";

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
    const toggle = page.locator("button.acpmux-session-info-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    return toggle;
  };
  const closeSessionInfo = async (page: Page) => {
    const toggle = await showToggle(page);
    if ((await page.locator("aside.acpmux-session-info").count()) > 0) {
      await toggle.click({ force: true });
      await page.locator("aside.acpmux-session-info").waitFor({ state: "detached", timeout: 5_000 });
    }
    await settle(page);
  };
  const openSessionInfo = async (page: Page, push: boolean) => {
    if (push) await sessionInfoPushAlways(page);
    const toggle = await showToggle(page);
    if ((await page.locator("aside.acpmux-session-info").count()) === 0) await toggle.click({ force: true });
    await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
    await settle(page);
  };
  /// Settings > Agent Chat > Prompt Rail Side, as the rail's right-click menu writes it (railSide.ts).
  const railSide = (page: Page, side: "left" | "right") =>
    page.evaluate(async (side) => {
      const url = "/chatDisplay.ts";
      const display = (await import(/* @vite-ignore */ url)) as { setChatDisplay(value: unknown): void };
      display.setChatDisplay({ "agentPane.display.rail.side": side });
    }, side);
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
        occluded: nav.hasAttribute("data-occluded"),
        insidePane: box.left >= shell.left - 0.5 && box.right <= shell.right + 0.5 && bar.width > 0,
        clearOfColumn: box.right <= column + 0.5,
        distance: Math.round((column - box.right) * 10) / 10,
      };
    });

  for (const name of browsers.keys())
    for (const width of [1600, 1200, 1084, 800, 780, 760])
      test(`${name}: in a ${width}px pane the rail stays pinned while the chat moves`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          await closeSessionInfo(page);
          const closed = await rail(page);
          if (process.env.RAIL_CAPTURE_DIR && [1600, 1084, 800, 760].includes(width))
            await page.screenshot({ path: `${process.env.RAIL_CAPTURE_DIR}/${width}-closed.png` });
          await openSessionInfo(page, false);
          const open = await rail(page);
          if (process.env.RAIL_CAPTURE_DIR && [1600, 1084, 800, 760].includes(width))
            await page.screenshot({ path: `${process.env.RAIL_CAPTURE_DIR}/${width}-open.png` });
          if (width === 1084 && process.env.RAIL_GUTTER_SCREENSHOT) {
            await page.screenshot({ path: process.env.RAIL_GUTTER_SCREENSHOT });
          }
          // Push always narrows the chat to the pane less the panel; the rail stays pinned to the pane
          // edge and uses its own spacing-token inset.
          await closeSessionInfo(page);
          await openSessionInfo(page, true);
          const pushed = await rail(page);
          // The rail is pinned to the pane edge. Its inset grows from space-2 to space-4 with room;
          // the chat column may therefore overlap it at narrow widths without hiding the rail.
          const railInset = Math.min(16, Math.max(8, Math.round(width / 100)));
          for (const state of [closed, open, pushed]) {
            expect(state).toMatchObject({ shown: true, insidePane: true });
            expect(state.occluded).toBe(state.distance! < -0.5);
          }
          expect(closed.scrollbarPinned).toBe(true);
          expect(open.scrollbarPinned).toBe(true);
          expect(pushed.scrollbarPinned).toBe(false);
          expect([closed.left, open.left, pushed.left]).toEqual([railInset, railInset, railInset]);
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
          await closeSessionInfo(page);
          await page.locator(".acpmux-minimap__tick").first().focus();
          const card = page.locator(".acpmux-minimap__card");
          await card.waitFor({ state: "visible" });
          // Keep this same preview open while Session Info changes independently of pointer/focus.
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
            page.locator("button.acpmux-session-info-toggle").evaluate((node) => (node as HTMLElement).click());
          for (const open of [true, false, true]) {
            await toggle();
            await page.locator("aside.acpmux-session-info").waitFor({ state: open ? "visible" : "detached" });
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

  test("chromium: the pane-pinned rail stays put when the native right pane closes", async () => {
    current = browsers.get("chromium");
    if (!current) return;
    const page = await pane!.open({ width: 1200, height: 700 });
    try {
      await closeSessionInfo(page);
      await openSessionInfo(page, false);
      await page.evaluate(() => {
        const samples: { railLeft: number; railRight: number; columnLeft: number; cardLeft: number | null }[] = [];
        const stop = window.cmuxAfterPaint(() => {
          const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
          if (shell.clientWidth !== 1600) return true;
          const rail = document.querySelector<HTMLElement>(".acpmux-minimap__rail:not(.acpmux-scrollmap)")!;
          const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")];
          const card = document.querySelector<HTMLElement>(".acpmux-minimap__card");
          const railBox = rail.getBoundingClientRect();
          samples.push({
            railLeft: railBox.left,
            railRight: railBox.right,
            columnLeft: Math.min(...rows.map((row) => row.getBoundingClientRect().left)),
            cardLeft: card?.getBoundingClientRect().left ?? null,
          });
          return samples.length < 12;
        });
        Object.assign(window, { railResizeTrace: { samples, stop } });
      });
      await page.setViewportSize({ width: 1600, height: 700 });
      await page.waitForFunction(
        () => (window as unknown as { railResizeTrace: { samples: unknown[] } }).railResizeTrace.samples.length >= 4,
      );
      const samples = await page.evaluate(() => {
        const trace = (window as unknown as { railResizeTrace: { samples: unknown[]; stop(): void } }).railResizeTrace;
        trace.stop();
        return trace.samples as { railLeft: number; railRight: number; columnLeft: number; cardLeft: number | null }[];
      });
      if (process.env.RAIL_RESIZE_SCREENSHOT) await page.screenshot({ path: process.env.RAIL_RESIZE_SCREENSHOT });
      const paneInset = Math.min(16, Math.max(8, Math.round(1600 / 100)));
      expect(samples.every((sample) => Math.abs(sample.railLeft - paneInset) <= 1)).toBe(true);
      expect(
        samples.every((sample) => sample.cardLeft === null || Math.abs(sample.cardLeft - sample.railRight) <= 1),
      ).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("chromium: leaving a wide rail does not leave it revealed after narrowing", async () => {
    current = browsers.get("chromium");
    if (!current) return;
    const page = await pane!.open({ width: 1600, height: 700 });
    try {
      await closeSessionInfo(page);
      await page.locator(".acpmux-minimap__tick").first().hover();
      await page.locator(".acpmux-minimap__card").waitFor({ state: "visible" });
      await page.mouse.move(1000, 500);
      await page.locator(".acpmux-minimap__card").waitFor({ state: "detached" });
      await page.setViewportSize({ width: 160, height: 700 });
      await page.waitForFunction(() => document.querySelector(".acpmux-minimap__rail")?.hasAttribute("data-occluded"));
      expect(await page.locator(".acpmux-minimap__strip").count()).toBe(1);
    } finally {
      await page.close();
    }
  });

  for (const width of [760, 160])
    test(`chromium: a ${width}px pane keeps a live hover strip that reveals the rail`, async () => {
      current = browsers.get("chromium");
      if (!current) return;
      const page = await pane!.open({ width, height: 700 });
      try {
        await closeSessionInfo(page);
        const nav = page.locator(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
        const strip = page.locator(".acpmux-minimap__strip");
        await nav.waitFor();
        await strip.waitFor();
        expect(await nav.getAttribute("data-occluded")).toBe("true");
        await strip.hover();
        await page.waitForFunction(
          () => !document.querySelector(".acpmux-minimap__rail")?.hasAttribute("data-occluded"),
        );
        await nav.locator(".acpmux-minimap__tick").first().hover();
        await page.locator(".acpmux-minimap__card").waitFor({ state: "visible", timeout: 10_000 });
        if (process.env.RAIL_NARROW_HOVER_SCREENSHOT)
          await page.screenshot({ path: process.env.RAIL_NARROW_HOVER_SCREENSHOT });
        const card = page.locator(".acpmux-minimap__card");
        await card.hover({ position: { x: 12, y: 12 } });
        expect(await nav.getAttribute("data-occluded")).toBeNull();
        const box = await nav.boundingBox();
        const preview = await card.boundingBox();
        expect(Math.abs(preview!.x - box!.x - box!.width)).toBeLessThanOrEqual(1);
        // A click and a wheel gesture still navigate the transcript after revealing over the text.
        await nav.locator(".acpmux-minimap__tick").first().click();
        await page.waitForFunction(() => document.querySelector(".acpmux-scroll")!.scrollTop < 100);
        await page.mouse.wheel(0, 300);
        await page.waitForFunction(() => document.querySelector(".acpmux-scroll")!.scrollTop > 100);
        const first = await nav.locator(".acpmux-minimap__tick").first().boundingBox();
        await page.mouse.move(first!.x + 5, first!.y + 5);
        await page.mouse.down();
        await page.mouse.move(first!.x + 5, first!.y + 65, { steps: 5 });
        await page.mouse.up();
        await page.waitForFunction(() => document.querySelector(".acpmux-scroll")!.scrollTop > 300);
        await page.locator(".acpmux-header").click({ position: { x: Math.min(100, width - 10), y: 10 } });
        await page.mouse.move(width - 10, 350);
        await page.waitForFunction(() =>
          document.querySelector(".acpmux-minimap__rail")?.hasAttribute("data-occluded"),
        );
        if (process.env.RAIL_NARROW_SCREENSHOT) await page.screenshot({ path: process.env.RAIL_NARROW_SCREENSHOT });
      } finally {
        await page.close();
      }
    });
  // The right-edge rail is the left one mirrored (design/session-rail.md): the same pane-edge inset
  // from the right edge, card.right == rail.left, and the narrow pane's live strip at the right edge.
  for (const name of browsers.keys())
    for (const width of [1600, 1084, 760])
      test(`${name}: in a ${width}px pane the right-edge rail mirrors the left one`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          await closeSessionInfo(page);
          await railSide(page, "right");
          const nav = page.locator('.acpmux-minimap__rail[data-side="right"]:not(.acpmux-scrollmap)');
          await nav.waitFor({ state: "attached" });
          await settle(page);
          const railInset = Math.min(16, Math.max(8, Math.round(width / 100)));
          const placed = await page.evaluate(() => {
            const scroller = document.querySelector(".acpmux-scroll")!;
            const rail = document.querySelector(".acpmux-minimap__rail")!.getBoundingClientRect();
            const strip = document.querySelector(".acpmux-minimap__strip")!.getBoundingClientRect();
            // The scroller's content box: its right edge less its own scrollbar.
            const box = scroller.getBoundingClientRect();
            const edge = box.left + (scroller as HTMLElement).clientLeft + (scroller as HTMLElement).clientWidth;
            return { inset: Math.round(edge - rail.right), stripRight: Math.round(edge - strip.right) };
          });
          expect(placed).toEqual({ inset: railInset, stripRight: 0 });
          const occluded = (await nav.getAttribute("data-occluded")) !== null;
          expect(occluded).toBe(width === 760);
          if (occluded) {
            await page.locator(".acpmux-minimap__strip").hover();
            await page.waitForFunction(
              () => !document.querySelector(".acpmux-minimap__rail")?.hasAttribute("data-occluded"),
            );
          }
          await nav.locator(".acpmux-minimap__tick").first().hover();
          const card = page.locator(".acpmux-minimap__card");
          await card.waitFor({ state: "visible", timeout: 10_000 });
          await settle(page);
          const box = (await nav.boundingBox())!;
          const preview = (await card.boundingBox())!;
          expect(Math.abs(preview.x + preview.width - box.x)).toBeLessThanOrEqual(1);
          if (process.env.RAIL_CAPTURE_DIR)
            await page.screenshot({ path: `${process.env.RAIL_CAPTURE_DIR}/${width}-right-${name}.png` });
        } finally {
          await page.close();
        }
      });
});
