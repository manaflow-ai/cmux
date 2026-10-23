// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// cmux-web-test-timeout: 600
// Where a mouse wheel's glide on the transcript stops (wheelGlide.ts, #24327 review): a switch to
// another chat ends it, so the old chat's distance never moves the new one; and a notch over a part
// that scrolls on its own (a code view, a long tool output) ends it where it is, since the wheel
// belongs to that part now; and a page hidden mid-glide ends it at once, since WebKit holds a hidden
// page's frames and the first one back would finish the glide in one jump; and a glide to the bottom
// while a reply streams lands at the bottom the reply grew to, so the chat follows the reply again.
//
// The transcript harness (test/browser/transcript-follow.harness.tsx) in real Chromium and WebKit;
// the notch is the event macOS WebKit dispatches for a mouse wheel (100.006103515625px,
// wheelDeltaY 300). CI fails the file when it cannot launch them (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-wheel-glide.test.ts", async () => {
  setDefaultTimeout(120_000);
  // Each engine launches once and is kept (agent-pane-wheel-glide.test.ts says why).
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`transcript-wheel-glide: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("wheel glide stops", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  let at = 0;
  const history = (chat: string, turns: number) =>
    Array.from({ length: turns }, (_, index) => [
      { id: `${chat}-${index}-user`, kind: "user", text: `Question ${index}`, version: 1, at: (at += 1_000) },
      {
        id: `${chat}-${index}-answer`,
        kind: "assistant",
        text: `Answer ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, then watched the light sweep the water.`,
        version: 1,
        at: (at += 1_000),
      },
    ]).flat();
  const painted = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);

  /// The harness with a 60-turn chat, scrolled to its middle and at rest.
  async function open(name: string): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate(
      (rows) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(rows),
      history("a", 60),
    );
    await painted(page, 20);
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = Math.round((scroller.scrollHeight - scroller.clientHeight) / 2);
    });
    await painted(page, 20);
    return page;
  }

  /// Dispatches one macOS WebKit notch (`deltaY` px) on the row under the transcript's middle;
  /// whether the page took it.
  const notch = (page: Page, deltaY: number) =>
    page.evaluate((deltaY) => {
      const box = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
      const over = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)!;
      return !over.dispatchEvent(
        new WheelEvent("wheel", {
          deltaY,
          wheelDeltaY: Math.trunc(-3 * deltaY),
          bubbles: true,
          cancelable: true,
          composed: true,
        } as WheelEventInit),
      );
    }, deltaY);

  /// A chat whose last reply is still streaming, `paragraphs` long.
  const streaming = (paragraphs: number) => [
    ...history("s", 30),
    { id: "s-live-user", kind: "user", text: "Tell me about the lighthouse.", version: 1, at: 900_000 },
    {
      id: "s-live-answer",
      kind: "assistant",
      text: Array.from(
        { length: paragraphs },
        (_, index) => `Paragraph ${index}. The keeper wiped the salt from the lantern glass and watched the light.`,
      ).join("\n\n"),
      version: paragraphs,
      streaming: true,
      at: 900_001,
    },
  ];
  const show = (page: Page, rows: unknown) =>
    page.evaluate((rows) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(rows), rows);
  /// How far the view's bottom is above the transcript's end, in pixels.
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
    });

  for (const name of browsers.keys()) {
    describe(name, () => {
      test("a switch to another chat mid-glide leaves the new chat where it opened", async () => {
        const page = await open(name);
        // Three notches up: 300px to glide.
        for (let index = 0; index < 3; index += 1) expect(await notch(page, -100.006103515625)).toBe(true);
        await painted(page, 2);
        await page.evaluate(
          (rows) =>
            (window as unknown as { __switchSession(id: string, rows: unknown): void }).__switchSession(
              "session-2",
              rows,
            ),
          history("b", 40),
        );
        // The new chat opens at its latest message and stays there, frame after frame.
        const fromEnd = await page.evaluate(async () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const offsets: number[] = [];
          for (let frame = 0; frame < 30; frame += 1) {
            await window.cmuxPaintFrame();
            offsets.push(Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop));
          }
          return offsets;
        });
        // A frame or two to place the new chat's rows, then at its end on every frame.
        expect(fromEnd.slice(3).filter((distance) => distance > 1)).toEqual([]);
        await page.close();
      });

      test("a notch over a part that scrolls on its own ends the glide where it is", async () => {
        const page = await open(name);
        // A part of a row that scrolls itself (as a code view or a long tool output does).
        await page.evaluate(() => {
          const box = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          const row = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)!;
          const part = document.createElement("div");
          part.className = "glide-test-nested";
          Object.assign(part.style, { height: "60px", overflowY: "auto" });
          part.innerHTML = "<div style='height: 600px'>output</div>";
          row.appendChild(part);
        });
        await painted(page, 20);
        // Partway down its own content, so the notch scrolls the part itself: WebKit's default wheel
        // handling scrolls for a dispatched event too, and a part at its top would hand an upward
        // notch on to the transcript, as a real wheel there does.
        await page.evaluate(() => (document.querySelector(".glide-test-nested")!.scrollTop = 300));
        await painted(page, 2);
        for (let index = 0; index < 3; index += 1) expect(await notch(page, -100.006103515625)).toBe(true);
        await painted(page, 3);
        // The part takes this notch (the page leaves it to the engine), and the content holds from the
        // next frame: where the part's row is on screen, not the offset (rows above that measure
        // change the offset to keep the reader's place, and nothing on screen moves for them).
        const after = await page.evaluate(async () => {
          const part = document.querySelector(".glide-test-nested > div")!;
          const row = (part.closest(".acpmux-row") as HTMLElement).dataset.rowId!;
          const taken = !part.dispatchEvent(
            new WheelEvent("wheel", {
              deltaY: -100.006103515625,
              wheelDeltaY: 300,
              bubbles: true,
              cancelable: true,
              composed: true,
            } as WheelEventInit),
          );
          const tops: number[] = [];
          for (let frame = 0; frame < 20; frame += 1) {
            await window.cmuxPaintFrame();
            tops.push(Math.round(document.querySelector(`[data-row-id="${row}"]`)!.getBoundingClientRect().top));
          }
          return { taken, tops };
        });
        expect(after.taken).toBe(false);
        expect(after.tops.slice(1).filter((top) => Math.abs(top - after.tops[0]!) > 1)).toEqual([]);
        await page.close();
      });

      test("a glide to the bottom while a reply streams lands at the grown bottom, and follows on", async () => {
        const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 560 } });
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
        await page.waitForFunction(() => "__showRows" in window);
        let paragraphs = 6;
        await show(page, streaming(paragraphs));
        await painted(page, 20);
        // The reader is 150px above the bottom: two notches down go to the bottom.
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = scroller.scrollHeight - scroller.clientHeight - 150;
        });
        await painted(page, 20);
        expect(await fromEnd(page)).toBeGreaterThan(100);
        for (let index = 0; index < 2; index += 1) expect(await notch(page, 100.006103515625)).toBe(true);
        await painted(page, 2);
        // The reply grows by several lines mid-glide, more than the follow deadband.
        paragraphs += 4;
        await show(page, streaming(paragraphs));
        await painted(page, 30);
        expect(await fromEnd(page)).toBeLessThanOrEqual(1);
        // And the chat follows the reply again: it grows, and the view stays at its end.
        for (let more = 0; more < 3; more += 1) {
          paragraphs += 3;
          await show(page, streaming(paragraphs));
          await painted(page, 6);
        }
        expect(await fromEnd(page)).toBeLessThanOrEqual(1);
        await page.close();
      });

      test("a page hidden mid-glide ends the glide where it is, and it stays there when shown", async () => {
        const page = await open(name);
        // Three notches up: 300px to glide.
        for (let index = 0; index < 3; index += 1) expect(await notch(page, -100.006103515625)).toBe(true);
        await painted(page, 2);
        // The document turns hidden, as a WKWebView's does when its tab, workspace or the app goes to
        // the background. A headless engine's page never hides, and its frames keep running, so the
        // page says it is hidden and fires the event the engine fires; any glide left running would
        // go on moving the content in those frames.
        const tops = await page.evaluate(async () => {
          const box = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          const row = (
            document
              .elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)!
              .closest(".acpmux-row") as HTMLElement
          ).dataset.rowId!;
          const top = () => Math.round(document.querySelector(`[data-row-id="${row}"]`)!.getBoundingClientRect().top);
          const visibility = (hidden: boolean) => {
            Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
            Object.defineProperty(document, "visibilityState", {
              configurable: true,
              get: () => (hidden ? "hidden" : "visible"),
            });
            document.dispatchEvent(new Event("visibilitychange"));
          };
          visibility(true);
          const hidden = top();
          const whileHidden: number[] = [];
          for (let frame = 0; frame < 15; frame += 1) {
            await window.cmuxPaintFrame();
            whileHidden.push(top());
          }
          visibility(false);
          const shown: number[] = [];
          for (let frame = 0; frame < 15; frame += 1) {
            await window.cmuxPaintFrame();
            shown.push(top());
          }
          return { hidden, whileHidden, shown };
        });
        const moved = [...tops.whileHidden, ...tops.shown].filter((top) => Math.abs(top - tops.hidden) > 1);
        expect(moved).toEqual([]);
        await page.close();
      });
    });
  }
});
