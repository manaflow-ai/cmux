// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The wheel over what floats on or under the transcript scrolls the transcript (Leo 2026-10-19:
// "can't scroll when cursor on the jump to bottom", "can't scroll from bottom composer area"), as in
// the Claude and Codex apps: over the Jump to latest button and over the composer's card. The
// button still jumps when clicked. (wheelPassThrough.ts)
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine) with real wheel events;
// CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/agent-pane-wheel-pass-through.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("agent-pane-wheel-pass-through.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-wheel-pass-through: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("wheel pass-through", () => test("browsers", () => {}));
    return;
  }
  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    pane = await papercutPane(() => current!, { turns: 30, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const scrollTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);

  /// Wheels `deltaY` with the pointer at the middle of `selector`'s box, and the scroll it made.
  async function wheelOver(page: Page, selector: string, deltaY: number): Promise<number> {
    const box = (await page.locator(selector).first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const before = await scrollTop(page);
    await page.mouse.wheel(0, deltaY);
    await page.waitForTimeout(400);
    return (await scrollTop(page)) - before;
  }

  for (const [name] of engines) {
    describe(name, () => {
      test("the wheel over Jump to latest scrolls the transcript, and a click still jumps", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        // Up from the latest message, so the button shows.
        expect(await wheelOver(page, ".acpmux-scroll", -1200)).toBeLessThan(0);
        await page.locator(".acpmux-jump-latest[data-shown]").waitFor();
        expect(await wheelOver(page, ".acpmux-jump-latest", -300)).toBeLessThan(-100);
        expect(await wheelOver(page, ".acpmux-jump-latest", 200)).toBeGreaterThan(100);
        await page.locator(".acpmux-jump-latest").click();
        await page.waitForTimeout(900);
        const end = await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
        });
        expect(end).toBeLessThan(2);
        await page.close();
      });

      test("the wheel over the composer scrolls the transcript", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        expect(await wheelOver(page, ".acpmux-composer-box", -300)).toBeLessThan(-100);
        expect(await wheelOver(page, ".acpmux-composer-box", 150)).toBeGreaterThan(50);
        await page.close();
      });
    });
  }
});
