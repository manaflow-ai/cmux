// The transcript never draws under the open Inspector (inspector/ChatInspector.tsx, inspector.css;
// Leo 2026-10-21: his message's bubble sat on Background tasks, and a message's Retry and Edit sat on
// "5 finished"). The panel used to lie over the chat at the pane's right edge while the rows kept the
// column's centered inset, so on a pane narrower than the column plus the panel a prompt's bubble,
// which sits at its row's right end, and the row's actions drew under the panel. On such a pane the
// default now pushes the chat aside: open, every row ends the page edge (18px) clear of the panel's
// left edge; closed, the rows take the column's centered place again.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/chat-inspector-overlay-transcript.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-overlay-transcript.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`chat-inspector-overlay-transcript: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("inspector overlay transcript", () => test("browsers", () => {}));
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
    test(`${name}: no transcript row draws under the open Inspector`, async () => {
      current = browsers.get(name)!;
      // 900px: the 720px column centered leaves 90px each side, less than the 320px panel.
      const page = await pane!.open({ width: 900, height: 620 });
      try {
        await page.evaluate(() => {
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
        });
        const panel = page.locator("aside.acpmux-chat-inspector");
        const toggle = page.locator("button.acpmux-chat-inspector-toggle");
        await toggle.waitFor({ timeout: 10_000 });
        await page.locator(".acpmux-scroll .acpmux-row .cv-user__bubble").first().waitFor({ timeout: 10_000 });
        if ((await panel.count()) === 0) await toggle.click({ force: true });
        // Too narrow for the panel beside the column: it pushes the chat (ChatInspector.tsx pushes).
        await page
          .locator('aside.acpmux-chat-inspector[data-placement="push"][data-presence="shown"]')
          .waitFor({ timeout: 10_000 });
        // The rows take their new width in the frame after the panel is drawn.
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const left = Math.round((await panel.boundingBox())!.x * 10) / 10;
        const open = await rowEdges(page);
        // The frame read the PR shows: the panel's left edge and the rows' right edges.
        console.log(`${name} open frame: panel left ${left}px, row rights ${JSON.stringify(open)}`);
        expect(open.rows.length).toBeGreaterThan(0);
        expect(open.bubbles.length).toBeGreaterThan(0);
        const under = [...open.rows, ...open.bubbles].filter((right) => right > left - 18 + 0.5);
        expect({ panelLeft: left, under }).toEqual({ panelLeft: left, under: [] });

        // Closed, the rows return to the column's centered place, past where the panel began.
        await toggle.click();
        await panel.waitFor({ state: "detached", timeout: 5_000 });
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const closed = await rowEdges(page);
        expect(Math.max(...closed.rows)).toBeGreaterThan(left + 100);
      } finally {
        await page.close();
      }
    });
});
