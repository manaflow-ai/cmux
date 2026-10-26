// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// In a short pane a grown prompt never pushes the composer card out of the pane (composer-scroll-2,
// found measuring Leo's double-scrollbar report, 2026-10-22). The bottom stack floats over the
// transcript's foot with a max-height (bottomStack.css). Before #24459 the card kept the prompt's
// whole eight-line height, so the stack's content ran past the stack's box: in a 260 px pane with a
// queued prompt, the card's last lines, its + and Send and the quiet row under it sat 86 px below the
// pane's bottom, where .acpmux-shell clips them (overflow: clip), out of reach. Now the card gives up
// the prompt's height: the prompt scrolls inside what is left, and every part of the stack ends inside
// the pane. Nothing else scrolls: the page and the pane's wrappers have no height past their boxes.
// agent-pane-bottom-stack.test.ts covers the stack's order in Chromium; this file grows the prompt
// itself and runs WebKit too.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts): a chat with a turn running and three queued prompts. Real Chromium (its
// classic scrollbars on) and WebKit (the app's engine); CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-short-pane-composer.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-short-pane-composer.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, launch] of [
    ["chromium", () => chromium.launch({ headless: true, timeout: 30_000, ignoreDefaultArgs: ["--hide-scrollbars"] })],
    ["webkit", () => webkit.launch({ headless: true, timeout: 30_000 })],
  ] as const) {
    try {
      browsers.set(name, await launch());
    } catch {
      console.warn(`agent-pane-short-pane-composer: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("short pane composer", () => test("browsers", () => {}));
    return;
  }

  const queue = ["one", "two", "three"].map((prompt, index) => ({
    promptId: `q-${index + 1}`,
    prompt: `${prompt} queued prompt`,
  }));
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, {
      turns: 30,
      running: true,
      session: { queued: queue.length, queue, steering: true, queuePaused: false },
      ready: ".acpmux-composer-queue",
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const painted = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let left = count; left > 0; left--) await window.cmuxPaintFrame();
    }, count);

  /// The page's fonts loaded and a frame painted with them: a late font (or a fallback swapped in)
  /// rewraps the prompt and moves every box after it, so nothing is grown or measured before that.
  const settled = async (page: Page) => {
    await page.evaluate(() => document.fonts.ready.then(() => undefined));
    await painted(page, 2);
  };

  /// Types a prompt of `lines` lines, past the prompt's eight-line cap.
  async function grow(page: Page, lines: number) {
    await settled(page);
    await page.locator(".acpmux-composer-prompt [contenteditable]").click();
    for (let line = 1; line <= lines; line++) {
      await page.keyboard.type(`line ${line} of a long prompt`);
      if (line < lines) await page.keyboard.press("Shift+Enter");
    }
    await painted(page, 6);
  }

  /// Where the stack's parts end against the pane, and every box that holds more than it shows.
  const measure = async (page: Page) => {
    await settled(page);
    return page.evaluate(() => {
      const rect = (selector: string) => document.querySelector(selector)?.getBoundingClientRect();
      const requiredRect = (selector: string) => {
        const box = rect(selector);
        if (!box) throw new Error(`expected ${selector} to be rendered`);
        return box;
      };
      const main = requiredRect(".acpmux-main");
      const past = (selector: string) => Math.round(requiredRect(selector).bottom - main.bottom);
      const overflow = (element: Element | null) =>
        element ? Math.max(0, element.scrollHeight - element.clientHeight) : null;
      const prompt = document.querySelector<HTMLElement>(".acpmux-composer-prompt")!;
      return {
        // How far each part of the stack ends below the pane's bottom (0 or less: inside it).
        past: {
          dock: past(".acpmux-main > .acpmux-dock"),
          card: past(".acpmux-composer-box"),
          foot: past(".acpmux-composer-foot"),
        },
        // Content past the box of the page and of the pane's wrappers: only the transcript, the
        // prompt and the queue scroll.
        overflow: {
          page: overflow(document.scrollingElement),
          body: overflow(document.body),
          root: overflow(document.getElementById("root")),
          shell: overflow(document.querySelector(".acpmux-shell")),
          main: overflow(document.querySelector(".acpmux-main")),
          dock: overflow(document.querySelector(".acpmux-main > .acpmux-dock")),
        },
        prompt: {
          height: prompt.getBoundingClientRect().height,
          cap: parseFloat(getComputedStyle(prompt).maxHeight),
          scrolls: prompt.scrollHeight > prompt.clientHeight + 1,
        },
        transcriptAbove: (rect(".acpmux-main > .acpmux-dock")?.top ?? 0) - (rect(".acpmux-scroll")?.top ?? 0),
      };
    });
  };

  const inside = { dock: 0, card: 0, foot: 0 };
  const flat = { page: 0, body: 0, root: 0, shell: 0, main: 0, dock: 0 };
  const clamp = (past: Record<string, number>) =>
    Object.fromEntries(Object.entries(past).map(([key, value]) => [key, Math.max(0, value)]));

  for (const name of browsers.keys())
    for (const [label, width, height] of [
      ["a 260 px pane", 900, 260],
      ["a 330 px pane", 900, 330],
      ["a narrow 420 px pane", 380, 420],
    ] as const)
      test(`${name}: in ${label} a grown prompt keeps the card, its controls and the quiet row inside the pane`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width, height });
        try {
          await grow(page, 16);
          const drawn = await measure(page);
          expect({ past: clamp(drawn.past) }).toEqual({ past: inside });
          expect(drawn.overflow).toEqual(flat);
          // The prompt gave up its height and scrolls in what is left, never under one line.
          expect(drawn.prompt.scrolls).toBe(true);
          expect(drawn.prompt.height).toBeGreaterThanOrEqual(40);
          // The transcript keeps its room over the stack (bottomStack.css, 64 px with the quiet row).
          expect(drawn.transcriptAbove).toBeGreaterThanOrEqual(63.5);
        } finally {
          await page.close();
        }
      });

  for (const name of browsers.keys())
    test(`${name}: in a tall pane the grown prompt takes 40% of the pane`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 900, height: 760 });
      try {
        await grow(page, 20);
        const drawn = await measure(page);
        expect({ past: clamp(drawn.past) }).toEqual({ past: inside });
        expect(drawn.overflow).toEqual(flat);
        // Its whole cap (markdownField.css max-height), 40% of the 760 px pane (Leo, 2026-10-24: "we
        // can afford to expand the composer text area a bit more"): room enough gives nothing up.
        expect(drawn.prompt.cap).toBeCloseTo(760 * 0.4, 0);
        expect(drawn.prompt.scrolls).toBe(true);
        expect(drawn.prompt.height).toBeGreaterThanOrEqual(drawn.prompt.cap - 0.5);
      } finally {
        await page.close();
      }
    });
});
