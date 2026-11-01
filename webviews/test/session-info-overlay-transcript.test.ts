// The transcript never draws under the open Session Info (session-info/SessionInfo.tsx, sessionInfo.css;
// Leo 2026-10-21: his message's bubble sat on Background tasks, and a message's Retry and Edit sat on
// "5 finished"). The panel floats outside the chat's layout and never moves it (Leo, 2026-10-29: "it's
// not supposed to be a fucking sidebar that pushes the fucking layout"): where the right gutter holds
// it, every row ends left of the panel; with Settings Push always, the chat narrows beside it and every
// row ends the page edge (18px) clear of it. Where the gutter cannot hold it, it floats over the chat
// (session-info-placement.test.ts). Closed, the rows take the column's centered place again.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/session-info-overlay-transcript.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { sessionInfoPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("session-info-overlay-transcript.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`session-info-overlay-transcript: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("session info overlay transcript", () => test("browsers", () => {}));
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

  /// Each drawn row's and prompt bubble's right edge, in page px.
  const rowEdges = (page: Page) =>
    page.evaluate(() => {
      const right = (selector: string) =>
        [...document.querySelectorAll(selector)]
          .map((element) => element.getBoundingClientRect())
          .filter((box) => box.width > 0 && box.height > 0)
          .map((box) => Math.round(box.right * 10) / 10);
      return {
        rows: right(".acpmux-scroll .acpmux-row"),
        bubbles: right(".acpmux-scroll .acpmux-row .cv-user__bubble"),
      };
    });

  for (const name of browsers.keys())
    for (const { width, placement, clear } of [
      // 1600px: the 400px gutter holds the 320px panel and its margins.
      { width: 1600, placement: "overlay", clear: 0 },
      // 900px: the 720px column centered leaves 90px each side, less than the 320px panel.
      { width: 900, placement: "push", clear: 18 },
    ] as const)
      test(`${name}: no transcript row draws under the open Session Info (${width}px, ${placement})`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 620 });
        try {
          if (placement === "push") await sessionInfoPushAlways(page);
          await page.evaluate(() => {
            (
              window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
            ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
          });
          const panel = page.locator("aside.acpmux-session-info");
          const toggle = page.locator("button.acpmux-session-info-toggle");
          await toggle.waitFor({ timeout: 10_000 });
          await page.locator(".acpmux-scroll .acpmux-row .cv-user__bubble").first().waitFor({ timeout: 10_000 });
          if ((await panel.count()) > 0) {
            await toggle.click({ force: true });
            await panel.waitFor({ state: "detached", timeout: 5_000 });
          }
          await page.evaluate(async () => {
            await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
            await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
          });
          // Where the rows draw with it closed: closing it again puts them back exactly here.
          const before = await rowEdges(page);
          await toggle.click({ force: true });
          await page
            .locator(`aside.acpmux-session-info[data-placement="${placement}"][data-presence="shown"]`)
            .waitFor({ timeout: 10_000 });
          // The rows take their new place once the chat's width has settled (Push always).
          await page.evaluate(async () => {
            await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
            await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
          });
          const left = Math.round((await panel.boundingBox())!.x * 10) / 10;
          const open = await rowEdges(page);
          // The frame read the PR shows: the panel's left edge and the rows' right edges.
          console.log(`${name} open frame: panel left ${left}px, row rights ${JSON.stringify(open)}`);
          expect(open.rows.length).toBeGreaterThan(0);
          expect(open.bubbles.length).toBeGreaterThan(0);
          const under = [...open.rows, ...open.bubbles].filter((right) => right > left - clear + 0.5);
          expect({ panelLeft: left, under }).toEqual({ panelLeft: left, under: [] });

          // Closed, the rows return to the column's centered place: where they drew before it opened, with
          // nothing of the push kept.
          await toggle.click();
          await panel.waitFor({ state: "detached", timeout: 5_000 });
          await page.evaluate(async () => {
            await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
            await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
          });
          const closed = await rowEdges(page);
          expect(closed.rows).toEqual(before.rows);
          // Floating, the rows never moved; pushed, they were narrowed and now reach past the panel's edge.
          if (placement === "push") expect(Math.max(...closed.rows)).toBeGreaterThan(left + 100);
          else expect(open.rows).toEqual(before.rows);
        } finally {
          await page.close();
        }
      });
});
