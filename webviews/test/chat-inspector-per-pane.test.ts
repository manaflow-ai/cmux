// Session Info (the Inspector, inspector/inspectorState.ts) is each chat pane's own. Leo, 2026-10-25:
// "basically the video shows the session rail opening and closing it opens and closes on the other
// side too when you do one... they should all be individual per pane". Two chat panes are two pages
// on one origin with one localStorage; the open state used to be one key every page followed through
// the `storage` event, so a toggle in the left pane closed the right one too. Here two pages share one
// browser context (one storage) and show the same chat, the hardest case: closing Session Info in the
// left one leaves the right one open, and the left one is still closed after a reload. (The same chat in two panes shares
// what a relaunch shows, its last choice; different chats each keep their own.)
//
// CMUX_BROWSER_TESTS=1 bun test test/chat-inspector-per-pane.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserContext, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-per-pane.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`chat-inspector-per-pane: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("inspector per pane", () => test("browsers", () => {}));
    return;
  }

  /// The context the panes open in: every page of it shares one localStorage, as the app's panes do.
  let context: BrowserContext | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => ({ newPage: () => context!.newPage() }) as unknown as Browser, {
      turns: 2,
      running: false,
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    context = await browsers
      .values()
      .next()
      .value!.newContext({ viewport: { width: 1200, height: 600 } });
    await (await pane.open()).close();
    await context.close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// Session Info offered (Debug Settings `agent.inspector`, pushed with the header state).
  const offer = (page: Page) =>
    page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } })
        .cmuxAcpmuxBridge;
      bridge.applyHeaderState({ inspector: true, version: 2 });
    });
  const shown = (page: Page) => page.locator('aside.acpmux-chat-inspector[data-presence="shown"]');
  const toggle = (page: Page) => page.locator("button.acpmux-chat-inspector-toggle");
  /// Waits until `page` sees another page's toggle (the last choice, `open`, in the storage they
  /// share; its storage event comes with it) and has painted two frames after it, so a pane that
  /// followed the event would show it.
  const seenAndPainted = async (page: Page, open: "0" | "1") => {
    await page.waitForFunction((value) => localStorage.getItem("cmux.agentPane.inspector.open") === value, open, {
      timeout: 5_000,
    });
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let painted = 0;
          window.cmuxAfterPaint(() => {
            if (++painted < 2) return true;
            resolve();
            return false;
          });
        }),
    );
  };

  for (const name of browsers.keys())
    test(`${name}: closing Session Info in one pane leaves the other pane's open`, async () => {
      context = await browsers.get(name)!.newContext({ viewport: { width: 1200, height: 600 } });
      try {
        const left = await pane!.open();
        const right = await pane!.open();
        for (const page of [left, right]) {
          await offer(page);
          await shown(page).waitFor({ timeout: 10_000 });
        }
        await toggle(left).click();
        await shown(left).waitFor({ state: "detached", timeout: 5_000 });
        // The left page's write has reached the right page, and the right page has painted twice since.
        await seenAndPainted(right, "0");
        const state = async (page: Page) => ({
          panel: await shown(page).count(),
          pressed: await toggle(page).getAttribute("aria-pressed"),
        });
        expect({ left: await state(left), right: await state(right) }).toEqual({
          left: { panel: 0, pressed: "false" },
          right: { panel: 1, pressed: "true" },
        });
        // The left pane after a relaunch: still closed.
        await left.reload();
        await left.getByText("Answer 2:", { exact: false }).waitFor({ timeout: 60_000 });
        await offer(left);
        await toggle(left).waitFor({ timeout: 10_000 });
        expect(await toggle(left).getAttribute("aria-pressed")).toBe("false");
        // The right pane's own toggle works on its own, and the left one does not follow it.
        await toggle(right).click();
        await shown(right).waitFor({ state: "detached", timeout: 5_000 });
        await toggle(right).click();
        await shown(right).waitFor({ timeout: 5_000 });
        await seenAndPainted(left, "1");
        expect(await shown(left).count()).toBe(0);
      } finally {
        await context.close();
      }
    });
});
