// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The wheel over Jump to latest scrolls the transcript (Leo 2026-10-19: "can't scroll when cursor on
// the jump to bottom"), as in the Claude and Codex apps, and the button still jumps when clicked.
// The bottom stack is a no-scroll zone (Leo 2026-10-20). (wheelPassThrough.ts)
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine) with real wheel events;
// CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/agent-pane-wheel-pass-through.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";

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

  /// The pane at its latest message, with the painted-frame helpers.
  async function open(): Promise<Page> {
    const page = await pane!.open();
    await installPaintedFrames(page);
    return page;
  }

  /// Resolves once the transcript's offset, the draft's offset and the composer card's box have held
  /// for 6 painted frames (Linux WebKit animates a wheel step over several frames).
  const still = (page: Page) =>
    page.evaluate(async () => {
      const read = () => {
        const card = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect();
        return [
          document.querySelector(".acpmux-scroll")?.scrollTop,
          document.querySelector(".acpmux-md-field")?.scrollTop,
          card?.y,
          card?.height,
        ].join(" ");
      };
      let last = read();
      for (let held = 0, frames = 0; held < 6 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const now = read();
        held = now === last ? held + 1 : 0;
        last = now;
      }
    });

  const scrollTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);

  /// Wheels `deltaY` with the pointer at the middle of `selector`'s box, and the scroll it made.
  async function wheelOver(page: Page, selector: string, deltaY: number): Promise<number> {
    const box = (await page.locator(selector).first().boundingBox())!;
    return wheelAt(page, box.x + box.width / 2, box.y + box.height / 2, deltaY);
  }

  /// Wheels `deltaY` with the pointer at (`x`, `y`), and the scroll it made.
  async function wheelAt(page: Page, x: number, y: number, deltaY: number): Promise<number> {
    await page.mouse.move(x, y);
    const before = await scrollTop(page);
    await page.mouse.wheel(0, deltaY);
    await still(page);
    return (await scrollTop(page)) - before;
  }

  for (const [name] of engines) {
    describe(name, () => {
      test("the wheel over Jump to latest scrolls the transcript, and a click still jumps", async () => {
        current = browsers.get(name);
        const page = await open();
        // Up from the latest message, so the button shows.
        expect(await wheelOver(page, ".acpmux-scroll", -1200)).toBeLessThan(0);
        await page.locator(".acpmux-jump-latest[data-shown]").waitFor();
        // The jump control keeps its own glass without washing out extra transcript lines.
        const fade = await page.evaluate(() =>
          getComputedStyle(document.querySelector(".acpmux-scroll")!).getPropertyValue("--acpmux-fade-bottom").trim(),
        );
        expect(fade).toBe("18px");
        expect(await wheelOver(page, ".acpmux-jump-latest", -300)).toBeLessThan(-100);
        expect(await wheelOver(page, ".acpmux-jump-latest", 200)).toBeGreaterThan(100);
        await page.locator(".acpmux-jump-latest").click();
        const distance = () =>
          page.evaluate(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
          });
        // The jump glides to the latest message.
        await page
          .waitForFunction(
            () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop < 2;
            },
            undefined,
            { timeout: 5_000 },
          )
          .catch(() => {});
        const end = await distance();
        expect(end).toBeLessThan(2);
        await page.close();
      });

      // Leo 2026-10-20: "all of these areas are essentially a no-scroll zone", but "if it's not in
      // the composer it should just scroll". The wheel over the composer's card moves neither the
      // transcript nor the stack; the wheel in the gutter beside the card scrolls the transcript.
      test("the wheel over the composer's card scrolls nothing, and beside it scrolls the transcript", async () => {
        current = browsers.get(name);
        const page = await open();
        // Up from the latest message, so the transcript can scroll either way.
        expect(await wheelOver(page, ".acpmux-scroll", -1200)).toBeLessThan(0);
        const card = (await page.locator(".acpmux-composer-box").first().boundingBox())!;
        const composer = (await page.locator(".acpmux-dock > .acpmux-composer").first().boundingBox())!;
        expect(card.x).toBeGreaterThan(composer.x + 12);
        const [x, y] = [card.x + card.width / 2, card.y + card.height / 2];
        // A wheel that got through moves the transcript 300 px; under 2 px is rows settling mid-history.
        for (const deltaY of [-300, 300]) {
          const moved = await wheelAt(page, x, y, deltaY);
          expect([deltaY, Math.abs(moved) < 2 ? 0 : moved]).toEqual([deltaY, 0]);
        }
        expect(await wheelAt(page, card.x - 8, y, -300)).toBeLessThan(-100);
        expect(await wheelAt(page, card.x - 8, y, 300)).toBeGreaterThan(100);
        await page.close();
      });

      // Leo 2026-10-20: "me scrolling within the composer, when I reach the top or the bottom, I
      // don't want that to shift." A long draft scrolls in its own box; the wheel that takes it to
      // either end, and the wheel after that, moves neither the transcript nor the box.
      test("the wheel over a long draft stops at its ends and moves nothing else", async () => {
        current = browsers.get(name);
        const page = await open();
        const prompt = page.locator(".acpmux-md-field").first();
        await prompt.click();
        await page.keyboard.insertText(Array.from({ length: 40 }, (_, i) => `draft line ${i + 1}`).join("\n"));
        await still(page);
        const field = () =>
          page.evaluate(() => {
            const box = document.querySelector<HTMLElement>(".acpmux-md-field")!;
            const rect = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
            return { top: box.scrollTop, end: box.scrollHeight - box.clientHeight, y: rect.y, height: rect.height };
          });
        const typed = await field();
        expect(typed.end).toBeGreaterThan(100);
        // The caret's whole line stays in view while typing.
        const caret = await page.evaluate(() => {
          const box = document.querySelector(".acpmux-md-field")!.getBoundingClientRect();
          const line =
            getSelection()!.getRangeAt(0).getClientRects()[0] ??
            getSelection()!.focusNode!.parentElement!.getBoundingClientRect();
          return { above: box.top - line.top, below: line.bottom - box.bottom };
        });
        expect(caret.above).toBeLessThanOrEqual(0);
        expect(caret.below).toBeLessThanOrEqual(0);

        expect(await wheelOver(page, ".acpmux-md-field", -2000)).toBe(0);
        expect((await field()).top).toBe(0);
        expect(await wheelOver(page, ".acpmux-md-field", -400)).toBe(0);
        expect(await wheelOver(page, ".acpmux-md-field", 2000)).toBe(0);
        const end = await field();
        expect(end.end - end.top).toBeLessThan(2);
        expect(await wheelOver(page, ".acpmux-md-field", 400)).toBe(0);
        let after = await field();
        expect(after.y).toBe(typed.y);
        expect(after.height).toBe(typed.height);

        // ↑ and ↓ past the draft's first and last lines move only the caret and the draft.
        const transcript = await scrollTop(page);
        for (let step = 0; step < 45; step++) await page.keyboard.press("ArrowUp");
        await still(page);
        // The first line's text shows in full (the browser's own caret reveal may tuck the line
        // box's leading under the edge on Linux, the glyphs stay in view).
        const firstLine = await page.evaluate(() => {
          const box = document.querySelector(".acpmux-md-field")!;
          const text = document.createRange();
          text.selectNodeContents(box.querySelector("p")!.firstChild!);
          return text.getClientRects()[0]!.top - box.getBoundingClientRect().top;
        });
        expect(firstLine).toBeGreaterThanOrEqual(0);
        for (let step = 0; step < 45; step++) await page.keyboard.press("ArrowDown");
        await still(page);
        after = await field();
        const lastLine = await page.evaluate(() => {
          const box = document.querySelector(".acpmux-md-field")!;
          const text = document.createRange();
          text.selectNodeContents([...box.querySelectorAll("p")].at(-1)!.firstChild!);
          return box.getBoundingClientRect().bottom - [...text.getClientRects()].at(-1)!.bottom;
        });
        expect(lastLine).toBeGreaterThanOrEqual(0);
        expect(await scrollTop(page)).toBe(transcript);
        expect(after.y).toBe(typed.y);
        expect(after.height).toBe(typed.height);
        await page.close();
      });
    });
  }
});
