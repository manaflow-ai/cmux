// l10n-allow-file: test fixture prompts, not shipped UI.
// Focus paints; it never moves anything (Leo, 2026-11-06: "if there's a focus ring, and then I
// click into a chat and I refocus it, like it does a little jump and a hop. There's, like, layout
// shift galore."). A chat going from "pane not key" to "key" to "composer focused" and back changes
// only colors, rims and the caret: every box in the chat (the header, the transcript, the queue, the
// composer and its rows) stays where it was, and the transcript keeps its scroll position. Checked in
// each top strip look (`data-top-strip`), with prompts queued over the card, in a started chat and
// in one still showing its location strip.
//
// The real agent pane (vite.config.acpmux-pane.mjs) with the papercut stand-in daemon. Real WebKit
// (the engine cmux NEXT draws with); CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/chat-focus-paints-only.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { webkit, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-focus-paints-only.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("chat-focus-paints-only: skipping (run `bunx playwright install webkit`)");
    describe.skip("chat focus paints only", () => test("webkit", () => {}));
    return;
  }
  const queue = ["first", "second"].map((prompt, index) => ({
    promptId: `q-${index + 1}`,
    prompt: `${prompt} queued`,
  }));
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  let page: Page;
  beforeAll(async () => {
    browser = await webkit.launch({ headless: true });
    pane = await papercutPane(() => browser, {
      turns: 6,
      running: true,
      session: { steering: true, queuePaused: false, queued: queue.length, queue },
      ready: ".acpmux-composer-prompt",
    });
    page = await pane.open({ width: 900, height: 700 });
    await page.locator(".acpmux-composer-queue").first().waitFor({ state: "attached" });
  });
  afterAll(async () => {
    await page?.close();
    await pane?.close();
    await browser?.close();
  });

  /// Every drawn box in the chat, keyed by its place in the tree, and the transcript's scroll.
  const boxes = () =>
    page.evaluate(() => {
      const out: Record<string, string> = {};
      const walk = (element: Element, key: string) => {
        const box = element.getBoundingClientRect();
        if (box.width > 0 || box.height > 0)
          out[key] = [box.x, box.y, box.width, box.height].map((n) => Math.round(n * 4) / 4).join(" ");
        [...element.children].forEach((child, index) => walk(child, `${key}>${child.tagName}${index}`));
      };
      for (const selector of [".acpmux-header", ".acpmux-composer"]) {
        const root = document.querySelector(selector);
        if (root) walk(root, selector);
      }
      out.scrollTop = String(document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? -1);
      return out;
    });
  /// Twelve painted frames: a focus change's transitions and any follow-up layout have landed.
  const settle = () =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let frames = 0;
          window.cmuxAfterPaint(() => {
            if (++frames < 12) return true;
            resolve();
            return false;
          });
        }),
    );
  /// The boxes that differ from `before`, as `key: before -> after`.
  const moved = (before: Record<string, string>, after: Record<string, string>) =>
    [...new Set([...Object.keys(before), ...Object.keys(after)])]
      .filter((key) => before[key] !== after[key])
      .map((key) => `${key}: ${before[key] ?? "none"} -> ${after[key] ?? "none"}`);

  const states: [string, () => Promise<void>][] = [
    // The pane is not the key one (pageKey.ts marks the root), nothing in it focused.
    [
      "pane away",
      () =>
        page.evaluate(() => {
          (document.activeElement as HTMLElement | null)?.blur();
          document.documentElement.dataset.pageInactive = "";
        }),
    ],
    // The pane comes back: the root is key again, still nothing focused.
    ["pane key", () => page.evaluate(() => void delete document.documentElement.dataset.pageInactive)],
    // A click into the composer.
    ["composer focused", () => page.locator(".acpmux-composer-prompt").first().click()],
    // The pane goes away with the composer still holding DOM focus (another pane took the keyboard).
    [
      "pane away, composer focused",
      () => page.evaluate(() => void (document.documentElement.dataset.pageInactive = "")),
    ],
    // Back: the composer is refocused.
    [
      "composer refocused",
      async () => {
        await page.evaluate(() => void delete document.documentElement.dataset.pageInactive);
        await page.locator(".acpmux-composer-prompt").first().click();
      },
    ],
  ];

  for (const strip of ["", "bump", "plain", "tray"])
    for (const withStrip of [false, true])
      test(`top strip ${strip || "default"}, ${withStrip ? "location strip shown" : "started chat"}: focus moves no box`, async () => {
        await page.evaluate(
          ({ strip, withStrip }) => {
            const root = document.documentElement;
            if (strip) root.setAttribute("data-top-strip", strip);
            else root.removeAttribute("data-top-strip");
            // A new chat's location strip sits between the queue and the card (ComposerContext.tsx).
            const composer = document.querySelector(".acpmux-composer")!;
            composer.querySelector(":scope > .acpmux-composer-strip[data-test-strip]")?.remove();
            if (withStrip && !composer.querySelector(":scope > .acpmux-composer-strip")) {
              const added = document.createElement("div");
              added.className = "acpmux-composer-strip";
              added.dataset.testStrip = "";
              composer.insertBefore(added, composer.querySelector(":scope > .acpmux-composer-box"));
            }
          },
          { strip, withStrip },
        );
        await states[0]![1]();
        await settle();
        const rest = await boxes();
        const shifts: string[] = [];
        for (const [name, enter] of states.slice(1)) {
          await enter();
          await settle();
          for (const line of moved(rest, await boxes())) shifts.push(`${name}: ${line}`);
        }
        expect(shifts).toEqual([]);
      });
});
