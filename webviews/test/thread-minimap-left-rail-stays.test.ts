// The thread rail (threadMinimap/ThreadMinimap.tsx) is never pushed aside by Session Info (Leo,
// 2026-10-25: "So the left rail thing, that still gets hidden. So, like, when that session rail is
// there, the session rail ends up pushing it to the side, and also when the left pane gets too narrow,
// the session rail still disappears. We can't have it disappear."). Session Info floats and moves the
// chat's column left only when both fit (inspector/ChatInspector.tsx inspectorChatShift); the rail
// stays at the pane's left edge while the column moves, and the move always leaves the rail its
// room. In a wide pane (1600), the pane where the column moves (1200), the pane where moving it
// would take the rail's room (1100), a narrow window (1000) and the narrowest pane the layout allows
// (200, cmux.json `layout.minimumPaneWidth`), with Session Info closed, open, and pushing (Push
// always): the rail draws (minimal under a 48px gutter, #24525), inside the pane, clear of the
// transcript's column, and Session Info opening leaves it where it was.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-left-rail-stays.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

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
    const toggle = page.locator("button.acpmux-chat-inspector-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    return toggle;
  };
  const closeInspector = async (page: Page) => {
    const toggle = await showToggle(page);
    if ((await page.locator("aside.acpmux-chat-inspector").count()) > 0) {
      await toggle.click({ force: true });
      await page.locator("aside.acpmux-chat-inspector").waitFor({ state: "detached", timeout: 5_000 });
    }
    await settle(page);
  };
  const openInspector = async (page: Page, push: boolean) => {
    if (push) await inspectorPushAlways(page);
    const toggle = await showToggle(page);
    if ((await page.locator("aside.acpmux-chat-inspector").count()) === 0) await toggle.click({ force: true });
    await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').waitFor({ timeout: 10_000 });
    await settle(page);
  };
  /// Where the rail draws, against the pane and the transcript's column (its rows' left edge).
  const rail = (page: Page) =>
    page.evaluate(() => {
      const nav = document.querySelector(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
      const shell = document.querySelector(".acpmux-shell")!.getBoundingClientRect();
      const rows = [...document.querySelectorAll(".acpmux-row")].map((row) => row.getBoundingClientRect().left);
      const column = Math.min(...rows);
      if (!nav) return { shown: false as const };
      const box = nav.getBoundingClientRect();
      // A tick's resting bar, as drawn.
      const bar = nav.querySelector(".acpmux-minimap__bar")!.getBoundingClientRect();
      return {
        shown: true as const,
        left: Math.round(box.left),
        insidePane: box.left >= shell.left - 0.5 && box.right <= shell.right + 0.5 && bar.width > 0,
        clearOfColumn: box.right <= column + 0.5,
      };
    });

  for (const name of browsers.keys())
    for (const width of [1600, 1200, 1100, 1000, 200])
      test(`${name}: in a ${width}px pane the rail stays put with Session Info closed, open and pushing`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height: 700 });
        try {
          const placed = { shown: true, insidePane: true, clearOfColumn: true };
          await closeInspector(page);
          const closed = await rail(page);
          await openInspector(page, false);
          const open = await rail(page);
          // Push always narrows the chat to the pane less the panel; the rail stays, minimal under a 48px
          // gutter (#24525).
          await closeInspector(page);
          await openInspector(page, true);
          const pushed = await rail(page);
          const where = ({ left: _left, ...rest }: { left?: number; shown: boolean }) => rest;
          expect({
            closed: where(closed),
            open: where(open),
            pushed: where(pushed),
            // Floating Session Info leaves the rail where it was.
            moved: closed.shown && open.shown ? open.left - closed.left : "hidden",
          }).toEqual({ closed: placed, open: placed, pushed: placed, moved: 0 });
        } finally {
          await page.close();
        }
      });
});
