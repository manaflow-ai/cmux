// The Inspector's toggle closes it (inspector/ChatInspector.tsx, inspector.css). Over the chat (the
// overlay placement, the default) the panel used to run the pane's full height, over the chat
// header too: the toggle at the header's end sat under the panel, so a click on it hit a
// section's disclosure button instead and no one could close the Inspector from its toggle. Open,
// the panel starts under the header, the toggle is the topmost element at its own centre, and a
// real mouse click there closes the panel without moving anything left on the page (the misplaced
// click folded the Environment section and Context jumped up under it, 84 px in the gallery, a layout
// shift the gallery graded as failing).
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/chat-inspector-overlay-toggle.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-overlay-toggle.test.ts", async () => {
  setDefaultTimeout(300_000);
  // Each engine launches once and stays up for the file: a probe launch closed before a second
  // launch left the second's first page never opening on a loaded Linux host.
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`chat-inspector-overlay-toggle: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("inspector overlay toggle", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    // The context the harness holds, so the Context section sits under Environment, as in the gallery.
    const usage = { sessionUpdate: "usage_update", used: 52_000, size: 200_000 };
    pane = await papercutPane(() => current!, {
      turns: 4,
      running: false,
      extra: [["in", "usage_update", { method: "session/update", params: { sessionId: "agent-1", update: usage } }]],
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// The chat with the Inspector on (Debug Settings `agent.inspector`, pushed with the header
  /// state), open over the chat and done entering.
  const openInspector = async (page: Page) => {
    await page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
      ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
    );
    const panel = page.locator("aside.acpmux-chat-inspector");
    const toggle = page.locator("button.acpmux-chat-inspector-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    if ((await panel.count()) === 0) await toggle.click({ force: true });
    await page.locator('aside.acpmux-chat-inspector[data-placement="overlay"][data-presence="shown"]').waitFor({
      timeout: 10_000,
    });
    return { panel, toggle };
  };

  for (const name of browsers.keys()) {
    test(`${name}: the toggle is above the open overlay and a click on it closes the Inspector`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 900, height: 520 });
      try {
        const { panel, toggle } = await openInspector(page);
        expect(await toggle.getAttribute("aria-pressed")).toBe("true");
        const box = (await toggle.boundingBox())!;
        const x = box.x + box.width / 2;
        const y = box.y + box.height / 2;
        const hit = await page.evaluate(
          ([px, py]) => {
            const element = document.elementFromPoint(px!, py!);
            if (element?.closest("button.acpmux-chat-inspector-toggle")) return "the toggle";
            return element ? `${element.tagName.toLowerCase()}.${element.className}` : "nothing";
          },
          [x, y],
        );
        // The panel starts at the header's foot, not over it.
        const header = (await page.locator("header.acpmux-header").boundingBox())!;
        const top = (await panel.boundingBox())!.y;
        // Where the panel's sections and the header sit, to see that the click moved none of them.
        const places = () =>
          page.evaluate(() =>
            Object.fromEntries(
              [...document.querySelectorAll("aside.acpmux-chat-inspector [data-section], header.acpmux-header")].map(
                (element) => [element.getAttribute("data-section") ?? "header", element.getBoundingClientRect().y],
              ),
            ),
          );
        const before = await places();
        await page.mouse.click(x, y);
        const closed = await panel
          .waitFor({ state: "detached", timeout: 5_000 })
          .then(() => true)
          .catch(() => false);
        const after = await places();
        // How far the click moved what it left on the page, in px (the misplaced click folded
        // Environment and Context jumped up).
        const moved = Math.max(
          0,
          ...Object.entries(after).map(([name, y]) => (name in before ? Math.abs(y - before[name]!) : 0)),
        );
        expect({
          hit,
          belowHeader: top >= header.y + header.height - 0.5,
          closed,
          pressed: await toggle.getAttribute("aria-pressed"),
          moved,
        }).toEqual({ hit: "the toggle", belowHeader: true, closed: true, pressed: "false", moved: 0 });
      } finally {
        await page.close();
      }
    });
  }
});
