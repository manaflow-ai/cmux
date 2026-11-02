// cmux-web-test-timeout: 240
// Session Info never lies over the transcript's text (session-info/SessionInfo.tsx `pushes`, Leo
// 2026-10-21: "a popup or dropdown-looking thing that DOESN'T close when you click out of it and
// DOESN'T shift the layout. OR it shifts the layout if there isn't enough space"). In a wide pane it
// floats in the right gutter beside the transcript's centered column, and the transcript does not
// move; in a narrow one, a pane of a split included, it pushes the chat aside, and the panel's rect
// meets no transcript row and not the composer. Either way it is a dropdown as tall as its sections,
// not a full-height column. A click elsewhere in the chat leaves it open; its toggle closes it. In Leo's
// chat it lay over the transcript at a narrow width: his prompt sat on "Background tasks".
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/session-info-placement.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { sessionInfoPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("session-info-placement.test.ts", async () => {
  setDefaultTimeout(300_000);
  // Each engine launches once and stays up for the file.
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`session-info-placement: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("session info placement", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, { turns: 4, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  type Box = { left: number; right: number; top: number; bottom: number };
  /// The transcript's rows and the composer, where they draw now.
  const transcript = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll(".acpmux-row, .acpmux-composer-box")].map((element) => {
        const { left, right, top, bottom } = element.getBoundingClientRect();
        return { left, right, top, bottom };
      }),
    );
  const meets = (a: Box, b: Box) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

  /// The chat with Session Info on (Debug Settings `agent.inspector`, pushed with the header
  /// state), open and done entering.
  const openSessionInfo = async (page: Page, push = false) => {
    if (push) await sessionInfoPushAlways(page);
    await page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
      ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
    );
    const panel = page.locator("aside.acpmux-session-info");
    const toggle = page.locator("button.acpmux-session-info-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    if ((await panel.count()) === 0) await toggle.click({ force: true });
    await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
    // The chat's shift beside it settles.
    await page.evaluate(() =>
      Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
    );
    return { panel, toggle };
  };
  /// The panel's rect.
  const rect = async (page: Page): Promise<Box> =>
    page.locator("aside.acpmux-session-info").evaluate((element) => {
      const { left, right, top, bottom } = element.getBoundingClientRect();
      return { left, right, top, bottom };
    });

  for (const name of browsers.keys()) {
    test(`${name}: in a wide pane it floats beside the transcript, which does not move`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1600, height: 700 });
      try {
        // Closed first, to see where the transcript draws without it.
        await page.evaluate(() =>
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
        );
        const toggle = page.locator("button.acpmux-session-info-toggle");
        await toggle.waitFor({ timeout: 10_000 });
        if ((await page.locator("aside.acpmux-session-info").count()) > 0) {
          await toggle.click();
          await page.locator("aside.acpmux-session-info").waitFor({ state: "detached", timeout: 5_000 });
        }
        const before = await transcript(page);
        const { panel } = await openSessionInfo(page);
        const box = await rect(page);
        const after = await transcript(page);
        expect(before.length).toBeGreaterThan(0);
        expect({
          placement: await panel.getAttribute("data-placement"),
          moved: after.map(
            (row, index) => Math.abs(row.left - before[index]!.left) + Math.abs(row.right - before[index]!.right),
          ),
          covers: after.filter((row) => meets(row, box)).length,
        }).toEqual({ placement: "overlay", moved: after.map(() => 0), covers: 0 });
      } finally {
        await page.close();
      }
    });

    // Leo, 2026-11-01: "why does the session info not push the layout left ever anymore". Where the
    // right gutter cannot hold it (a 1200px pane, a pane of a split at 560 and 700, a narrow window at
    // 900) it takes its column under the header: the chat moves left and narrows, and the panel covers
    // no row and not the composer. On base it floated over the chat's right end.
    for (const width of [560, 700, 900, 1200]) {
      test(`${name}: in a ${width}px pane it pushes the chat left and covers no row`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          const chat = () => page.evaluate(() => document.querySelector(".acpmux-main")!.getBoundingClientRect().width);
          const toggle = page.locator("button.acpmux-session-info-toggle");
          await page.evaluate(() =>
            (
              window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
            ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
          );
          await toggle.waitFor({ timeout: 10_000 });
          if ((await page.locator("aside.acpmux-session-info").count()) > 0) {
            await toggle.click();
            await page.locator("aside.acpmux-session-info").waitFor({ state: "detached", timeout: 5_000 });
          }
          const before = await chat();
          const { panel } = await openSessionInfo(page);
          const box = await rect(page);
          const rows = await transcript(page);
          const header = (await page.locator("header.acpmux-header").boundingBox())!;
          expect(rows.length).toBeGreaterThan(0);
          expect({
            placement: await panel.getAttribute("data-placement"),
            narrower: (await chat()) < before,
            underHeader: box.top >= header.y + header.height - 0.5,
            covers: rows.filter((row) => meets(row, box)),
          }).toEqual({ placement: "push", narrower: true, underHeader: true, covers: [] });
        } finally {
          await page.close();
        }
      });
    }

    // Settings > Agent Chat > Session Info: Push always takes a column and never covers a row or the composer.
    test(`${name}: with Push always in a 700px pane it pushes the chat, and never covers a row or the composer`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 700, height: 700 });
      try {
        const { panel } = await openSessionInfo(page, true);
        const box = await rect(page);
        const rows = await transcript(page);
        expect(rows.length).toBeGreaterThan(0);
        expect({
          placement: await panel.getAttribute("data-placement"),
          covers: rows.filter((row) => meets(row, box)),
        }).toEqual({ placement: "push", covers: [] });
      } finally {
        await page.close();
      }
    });

    // A dropdown that hugs its sections, never a full-height column of empty glass (Leo 2026-10-21:
    // "this BECAME A FUCKING SIDEBAR FOR NO FUCKING REASON ALL THIS FUCKING DEAD SPACE"): floating or
    // pushing, the panel is under half the pane's height with this chat's few short sections, and
    // the foot of the column it takes is the chat's page, not the panel.
    for (const width of [700, 1600]) {
      test(`${name}: in a ${width}px pane the panel hugs its sections and leaves the column's foot empty`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          const { panel } = await openSessionInfo(page);
          const box = await rect(page);
          const foot = await page.evaluate(
            ([x, y]) =>
              document.elementFromPoint(x!, y!)?.closest("aside.acpmux-session-info") ? "the panel" : "the page",
            [(box.left + box.right) / 2, 700 - 24],
          );
          expect({
            placement: await panel.getAttribute("data-placement"),
            short: box.bottom - box.top < 700 * 0.5,
            foot,
          }).toEqual({ placement: width === 700 ? "push" : "overlay", short: true, foot: "the page" });
        } finally {
          await page.close();
        }
      });
    }

    // A pane that narrows or widens past the gutter's room (a split opening beside it, a window drag)
    // draws the panel in its new place in the frame that draws the new width (Leo 2026-10-21: "WHY
    // DOES IT FLICKER"). The pane's width was read in a ResizeObserver and set as state that React
    // drew a frame or more later. Where the new gutter cannot hold it (1200px) it pushes the chat in
    // that same frame.
    for (const [from, to] of [
      [1600, 1200],
      [1200, 1600],
    ] as const)
      test(`${name}: from ${from}px to ${to}px the first frame at the new width has the panel in its new place`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width: from, height: 700 });
        try {
          await openSessionInfo(page);
          await page.evaluate((to) => {
            const w = window as unknown as {
              __placed?: { width: number; placement?: string; inset: number; overChat: boolean };
            };
            window.cmuxAfterPaint(() => {
              if (window.innerWidth !== to) return true;
              const panel = document.querySelector("aside.acpmux-session-info")!.getBoundingClientRect();
              const aside = document.querySelector<HTMLElement>("aside.acpmux-session-info");
              w.__placed = {
                width: window.innerWidth,
                placement: aside?.dataset.placement,
                inset: Math.round(window.innerWidth - panel.right),
                overChat: aside?.hasAttribute("data-over-chat") ?? false,
              };
              return false;
            });
          }, to);
          await page.setViewportSize({ width: to, height: 700 });
          await page.waitForFunction(() => (window as unknown as { __placed?: unknown }).__placed !== undefined);
          const placed = await page.evaluate(() => (window as unknown as { __placed: unknown }).__placed);
          expect(placed).toEqual({ width: to, placement: to === 1200 ? "push" : "overlay", inset: 8, overChat: false });
        } finally {
          await page.close();
        }
      });

    // Leo, 2026-10-31: "sometimes the claude code/chatgpt desktop just straight up make it a popover
    // that hides when you click away when the viewport is indeed too small". In a short pane where it
    // lies over the chat it is a popover a click elsewhere hides; in a tall one a click leaves it open.
    for (const height of [440, 700])
      test(`${name}: over the chat in a ${height}px tall pane a click in the composer ${height < 520 ? "hides" : "keeps"} it`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width: 700, height });
        try {
          const { panel, toggle } = await openSessionInfo(page);
          expect(await panel.getAttribute("data-popover")).toBe(height < 520 ? "" : null);
          // The composer's left end: the popover may lie over the rest of it.
          const composer = (await page.locator(".acpmux-md").first().boundingBox())!;
          await page.mouse.click(composer.x + 16, composer.y + composer.height / 2);
          await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
          if (height < 520) {
            await panel.waitFor({ state: "detached", timeout: 5_000 });
            await toggle.click();
            await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 5_000 });
          } else {
            expect(await panel.getAttribute("data-presence")).toBe("shown");
          }
        } finally {
          await page.close();
        }
      });

    test(`${name}: a click elsewhere in the chat leaves it open; its toggle closes it`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1600, height: 700 });
      try {
        const { panel, toggle } = await openSessionInfo(page);
        // The transcript's left gutter: nothing there takes the click.
        await page.mouse.click(8, 400);
        // Two painted frames: a close would have started its exit by then (ui/presence.ts).
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        expect({
          count: await panel.count(),
          presence: await panel.getAttribute("data-presence"),
        }).toEqual({ count: 1, presence: "shown" });
        await toggle.click();
        await panel.waitFor({ state: "detached", timeout: 5_000 });
        expect(await toggle.getAttribute("aria-pressed")).toBe("false");
      } finally {
        await page.close();
      }
    });
  }
});
