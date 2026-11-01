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
import { mkdirSync } from "node:fs";
import path from "node:path";
import { agentPaneTheme } from "../src/gallery/theme/web";
import { deriveTokens, GHOSTTY_DEFAULT, rgbHex } from "../src/gallery/theme/tokens";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

type Moved = { name: string; dx: number; dy: number; dw: number; dh: number };
type Probe = Window & {
  __stillBefore?: Map<Element, DOMRect>;
  __stillWorst?: Map<Element, Moved>;
  __stillStop?: () => void;
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
        !element.closest("aside.acpmux-session-info, .acpmux-cu-preview, button.acpmux-session-info-toggle") &&
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
          if (
            size(moved) > 0.5 &&
            size(moved) > size(probe.__stillWorst!.get(element) ?? { ...moved, dx: 0, dy: 0, dw: 0, dh: 0 })
          )
            probe.__stillWorst!.set(element, moved);
        }
      };
      // Read after each painted frame (support/paintedFrames.ts), until moved() stops it.
      probe.__stillStop = window.cmuxAfterPaint(sample);
    });
  /// Stops sampling and lists what moved, the outermost first.
  const moved = (page: Page) =>
    page.evaluate(() => {
      const probe = window as Probe;
      probe.__stillStop?.();
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
      (window as unknown as { cmuxAcpmuxBridge: { applyTabRow(row: unknown): void } }).cmuxAcpmuxBridge.applyTabRow({
        height: 28,
        trailingInset: 40,
      }),
    );
  const panel = (page: Page) => page.locator("aside.acpmux-session-info");
  const toggle = (page: Page) => page.locator("button.acpmux-session-info-toggle");
  const close = async (page: Page) => {
    if ((await panel(page).count()) === 0) return;
    await toggle(page).click({ force: true });
    await panel(page).waitFor({ state: "detached", timeout: 5_000 });
  };

  /// A window's frame: a synthetic 360x240 app window (title bar, sidebar, striped rows), so the card
  /// draws at its size in the stills.
  const FRAME =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAWgAAADwCAIAAACixWkYAAADnUlEQVR42u3dIQoAIBBFQe9/ToPZIGJZm1UFizCfdwKRqZtyLpJ0VfIEksAhCRySwCEJHJLAIUngkAQOSeCQBA5J4JAkcEgChyRwSAKHJHBIEjgkgUMSOCSBQxI4JIFDksAhCRySwCEJHJLAIUlbOGptWoWZHQwc4DADBzjMwAEOM3CAwwwc4DADh3wIM3CAwwwc4DADBzjMwAEOM3CAw8zAAQ4zcIDDDBzgMAMHOMzAAQ4zAwc4zMABDjNwgMMMHP/UR0jaBg5wSOAAhwQOcEjgAIcEDnBI4JAPIYEDHBI4wCGBAxwSOMAhgQMcksABDgkc4JDAAQ4JHOCQwAEOSeAAhwQOcEjgAIcEDnBI4ACHBA5egEMCBzgkcDjIZOYgEzjMwAEOM3CAw8zAAQ4zcIDDDBzgMAMHOMzAAQ4zAwc4zMABDjNwgMMMHOAwAwc4zAwc4DADBzjMwAEOM3CAwwwc4DADh8BhBg5wmIEDHGbgAIcZOMBhBg4HmSQ5yAQOCRzgkMABDgkc4JDAAQ5J4ACHBA5wSOAAhwQOcEjgAIckcIBDAgc4JHCAQwIHOCRwgEMCh8AhgQMcEjjAIYEDHBI4wCGBAxySwAEOCRzgkMDhIJOZg0zgMAMHOMwMHOAwAwc4zMABDjNwgMMMHOAwM3CAwwwc4DADBzjMwAEOM3CAwwwcAocZOMBhBg5wmIEDHGbgAIcZOMBhZuAAhxk4wGEGDnCYgQMcZuAAh5mBw0EmyUEmcEjgAIcEDnBI4ACHBA5egEMCBzgkcIBDAgc4JHCAQwIHOPwJCRzgkMABDgkc4JDAAQ4JHOCQBA5wSOAAhwQOcEjgAIcEDnBIAgc4JHCAQwIHOCRwOMhk5iATOMzAIXCYgQMcZuAAhxk4wGEGDnCYgQMcZgYOcJiBAxxm4ACHGTjAYQYOcJgZOMBhBg5wmIEDHGbgAIcZOMBhZuAAhxk4wGEGDnCYgQMcZuAAhxk4BA4zcDjIJDnIBA4JHOCQwAEOCRzgkAQOcEjgAIcEDnBI4ACHBA5wSAIHOCRwgEMCBzgkcIBDAgc4JIEDHBI4wCGBAxwSOMAhgQMcEjgEDgkc4JDAAQ4JHOCQwOEgk5mDTOAwM3CAwwwc4DADBzjMwAEOM3CAw8zAAQ4zcIDDDBzgMAMHOMzAAQ4zcMACHGbgAIcZOMBhBg5wmIEDHGbgAIeZgQMcZuAAhxk4wGEGDnCYgQMcZgYOcJg92gTLGv2E3aKKfgAAAABJRU5ErkJggg==";
  /// The host's computer use card, as AgentPaneComputerUsePreview pushes it.
  const computerUse = (page: Page) =>
    page.evaluate(async (frame) => {
      const url = "/computerUse/computerUsePreview.ts";
      const module = (await import(/* @vite-ignore */ url)) as { setComputerUsePreview(value: unknown): void };
      module.setComputerUsePreview({
        session: "cu-still",
        app: "Calculator",
        done: false,
        frame,
      });
    }, FRAME);

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
            await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
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

            // It closes.
            await mark(page);
            await close(page);
            await settle(page);
            const closing = await moved(page);
            expect({ opening, content, closing }).toEqual({ opening: [], content: [], closing: [] });
          } finally {
            await page.close();
          }
        });
      }
  // Stills for the pull request, when the run keeps an output folder (fast checks' FAST_CHECKS_OUT):
  // a 900px pane beside a computer use card, Session Info closed and open, 2x, light and dark.
  const out = process.env.FAST_CHECKS_OUT;
  if (out && browsers.has("chromium"))
    test("stills: Session Info closed and open beside a computer use card", async () => {
      current = browsers.get("chromium")!;
      mkdirSync(path.join(out, "stills"), { recursive: true });
      for (const colorScheme of ["light", "dark"] as const) {
        const page = await pane!.open({ width: 900, height: 640, scale: 2, colorScheme });
        try {
          // The pane's theme is the host's (applyTheme), not the browser's color scheme.
          const dark = colorScheme === "dark";
          const theme = agentPaneTheme(
            deriveTokens({
              ...GHOSTTY_DEFAULT,
              background: rgbHex(dark ? 0x1e1e1e : 0xffffff),
              foreground: rgbHex(dark ? 0xe5e5e5 : 0x1c1c1c),
            }),
            true,
          );
          await page.evaluate((theme) => window.cmuxAcpmuxBridge!.applyTheme(theme), theme);
          await computerUse(page);
          await page.locator(".acpmux-cu-preview").waitFor({ timeout: 10_000 });
          await header(page);
          await toggle(page).waitFor({ timeout: 10_000 });
          await close(page);
          await settle(page);
          await page.screenshot({ path: path.join(out, "stills", `session-info-closed-${colorScheme}.png`) });
          await toggle(page).click({ force: true });
          await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
          await settle(page);
          await page.screenshot({ path: path.join(out, "stills", `session-info-open-${colorScheme}.png`) });
        } finally {
          await page.close();
        }
      }
    });
});
