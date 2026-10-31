// cmux-web-test-timeout: 300
// Session Info never moves the chat around it (design/session-info.md rule 1; Leo, 2026-10-31: "why is
// the session info thing still pushing my layout when it doesnt need to???"). Every element outside
// the panel keeps its box while the panel opens, while it slides in, while its content changes (a
// section folds or unfolds), and after it closes again: the transcript, the composer's stack, the
// header and its tools, the thread rail, the minimap and the scroll bar. Measured in the default
// Overlay placement, in the pane's own header and under a native tab row, at a split's width, a
// narrow window and a wide one.
//
// The page is the pane's dev entry talking JSON-RPC to a stand-in acpmux (support/papercutChat.ts).
// Real Chromium and WebKit; CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/session-info-layout-still.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

type Moved = { name: string; dx: number; dy: number; dw: number; dh: number };
type Probe = Window & {
  __stillBefore?: Map<Element, DOMRect>;
  __stillWorst?: Map<Element, Moved>;
  __stillSampling?: boolean;
};

await requireBrowserLane("session-info-layout-still.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`session-info-layout-still: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("Session Info layout", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, { turns: 6, running: false });
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(async () => {
      await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
    });

  /// Records the box of every element outside Session Info, and starts sampling them every frame.
  const mark = (page: Page) =>
    page.evaluate(() => {
      const probe = window as Probe;
      // The computer use card moves under the panel by design (computerUsePreview.css), and the
      // toggle draws its on state (a fill, design/session-panel.md); the rest stays.
      const outside = (element: Element) =>
        !element.closest("aside.acpmux-chat-inspector, .acpmux-cu-preview, button.acpmux-chat-inspector-toggle") &&
        (element as HTMLElement).offsetParent !== null;
      probe.__stillBefore = new Map();
      probe.__stillWorst = new Map();
      for (const element of document.querySelectorAll("body *"))
        if (outside(element)) probe.__stillBefore.set(element, element.getBoundingClientRect());
      // Its tag and classes, under the nearest ancestor with a class when it has none (an icon's path).
      const name = (element: Element): string => {
        const own = `${element.tagName.toLowerCase()}.${[...element.classList].join(".")}`.replace(/\.$/, "");
        const named = element.classList.length > 0 ? undefined : element.parentElement?.closest("[class]");
        return named ? `${name(named)} ${own}` : own;
      };
      const sample = () => {
        for (const [element, was] of probe.__stillBefore!) {
          if (!element.isConnected || !outside(element)) continue;
          const now = element.getBoundingClientRect();
          const moved = {
            name: name(element),
            dx: Math.round((now.left - was.left) * 2) / 2,
            dy: Math.round((now.top - was.top) * 2) / 2,
            dw: Math.round((now.width - was.width) * 2) / 2,
            dh: Math.round((now.height - was.height) * 2) / 2,
          };
          const size = (one: Moved) => Math.abs(one.dx) + Math.abs(one.dy) + Math.abs(one.dw) + Math.abs(one.dh);
          if (size(moved) > 0.5 && size(moved) > size(probe.__stillWorst!.get(element) ?? { ...moved, dx: 0, dy: 0, dw: 0, dh: 0 }))
            probe.__stillWorst!.set(element, moved);
        }
        if (probe.__stillSampling) requestAnimationFrame(sample);
      };
      probe.__stillSampling = true;
      requestAnimationFrame(sample);
    });
  /// Stops sampling and lists what moved, the outermost first.
  const moved = (page: Page) =>
    page.evaluate(() => {
      const probe = window as Probe;
      probe.__stillSampling = false;
      const worst = probe.__stillWorst!;
      // An element that moved only because its ancestor did is the ancestor's move.
      return [...worst.entries()]
        .filter(([element, one]) => {
          for (let up = element.parentElement; up; up = up.parentElement) {
            const parent = worst.get(up);
            if (parent && parent.dx === one.dx && parent.dy === one.dy) return false;
          }
          return true;
        })
        .map(([, one]) => one)
        .slice(0, 12);
    });

  const header = (page: Page) =>
    page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
      ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
    );
  const tabRow = (page: Page) =>
    page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyTabRow(row: unknown): void } }
      ).cmuxAcpmuxBridge.applyTabRow({ height: 28, trailingInset: 40 }),
    );
  const panel = (page: Page) => page.locator("aside.acpmux-chat-inspector");
  const toggle = (page: Page) => page.locator("button.acpmux-chat-inspector-toggle");
  const close = async (page: Page) => {
    if ((await panel(page).count()) === 0) return;
    await toggle(page).click({ force: true });
    await panel(page).waitFor({ state: "detached", timeout: 5_000 });
  };

  /// The host's computer use card, as AgentPaneComputerUsePreview pushes it.
  const computerUse = (page: Page) =>
    page.evaluate(async () => {
      const url = "/computerUse/computerUsePreview.ts";
      const module = (await import(/* @vite-ignore */ url)) as { setComputerUsePreview(value: unknown): void };
      module.setComputerUsePreview({
        session: "cu-still",
        app: "Calculator",
        done: false,
        frame: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
      });
    });

  for (const name of browsers.keys())
    for (const [row, preview] of [
      [false, false],
      [true, false],
      [false, true],
    ] as const)
      for (const width of [560, 900, 1200, 1600]) {
        const where = `${width}px pane${row ? " under a tab row" : ""}${preview ? " beside a computer use card" : ""}`;
        test(`${name}: in a ${where}, opening, folding and closing Session Info moves nothing else`, async () => {
          current = browsers.get(name)!;
          const page = await pane!.open({ width, height: 760 });
          try {
            if (row) {
              await tabRow(page);
              await page.locator(".acpmux-header[data-tab-row]").waitFor({ timeout: 10_000 });
            }
            if (preview) {
              await computerUse(page);
              if (width >= 600) await page.locator(".acpmux-cu-preview").waitFor({ timeout: 10_000 });
            }
            await header(page);
            await toggle(page).waitFor({ timeout: 10_000 });
            await close(page);
            await settle(page);

            await mark(page);
            await toggle(page).click({ force: true });
            await page.locator('aside.acpmux-chat-inspector[data-presence="shown"]').waitFor({ timeout: 10_000 });
            await settle(page);
            const opening = await moved(page);

            // Its content changes: the first foldable section folds and unfolds.
            await mark(page);
            const fold = panel(page).locator("button[aria-expanded]").first();
            if ((await fold.count()) > 0) {
              await fold.click();
              await settle(page);
              await fold.click();
              await settle(page);
            }
            const content = await moved(page);

            await close(page);
            await settle(page);
            expect({ opening, content }).toEqual({ opening: [], content: [] });
          } finally {
            await page.close();
          }
        });
      }
});
