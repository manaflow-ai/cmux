// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A transcript at its latest message stays at its bottom (Leo 2026-10-21: "WHY IS THIS NOT
// IMMEDIATELY PUTTING ME AT THE BOTTOM EVERY SINGLE TIME"). A long chat opens at its end with
// nothing sliding it; a reply streamed a chunk per frame, and a tool row coming in under it, move
// the view in the frame that draws them, with no glide holding the new text below the view's foot;
// a prompt sent while the reader is scrolled up lands at the bottom on the next painted frame; and
// a reader who scrolled up is left where they scrolled while the reply grows. On base every chunk
// glid in (180 ms each), and a send left a scrolled-up reader where they were.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-pinned-bottom.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-pinned-bottom: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("pinned bottom", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const paragraph = (index: number) =>
    `Paragraph ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
    "then watched the light sweep the water for a while before going back down.";
  // Rich rows whose estimates differ from what draws: a heading, a list, a table and a code block.
  const rich = (index: number) =>
    `## Step ${index}\n\n${paragraph(index)}\n\n- one\n- two\n- three\n\n| a | b |\n| - | - |\n| ${index} | x |\n\n` +
    "```ts\nconst keeper = lantern.light();\nkeeper.sweep(water);\n```";
  const history = (turns: number): Row[] =>
    Array.from({ length: turns }, (_, index) => [
      row(`t${index}-user`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", rich(index)),
      row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
    ]).flat();
  const tool = (id: string) =>
    row(id, "activity", undefined, {
      items: [{ kind: "tool", text: "", tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed" } }],
    });

  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  const painted = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);

  type Frame = { fromEnd: number; glides: number };
  /// Samples every painted frame until `__stopSamples`: how far the offset is from the scroller's
  /// end, and how many animations move the thread (a glide holds the new text below the view's foot).
  const sample = (page: Page) =>
    page.evaluate(() => {
      const frames: { fromEnd: number; glides: number }[] = [];
      const own = window as unknown as { __samples: typeof frames; __stopSamples: () => void };
      own.__samples = frames;
      own.__stopSamples = window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const thread = scroller?.querySelector<HTMLElement>(".acpmux-thread");
        if (!scroller || !thread || !scroller.querySelector(".acpmux-row")) return;
        frames.push({
          fromEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
          glides: thread.getAnimations().length,
        });
      });
    });
  const samples = (page: Page) =>
    page.evaluate(() => {
      const own = window as unknown as { __samples: Frame[]; __stopSamples: () => void };
      own.__stopSamples();
      return own.__samples;
    });
  /// How far the view rests from its end, once its frames have painted.
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
    });

  for (const [name] of engines) {
    test(`${name}: a long chat opens at its bottom, a streamed reply and a tool row keep it there on every frame`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 560 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const opened = history(120);
      // From the first painted frame that has rows: the open, as drawn heights replace estimates.
      await sample(page);
      await show(page, opened);
      await painted(page, 30);
      const open = await samples(page);
      expect(open.length).toBeGreaterThan(0);
      // Drawn where it rests from its first frame: nothing slides it from estimated heights.
      expect(open.filter((frame) => frame.glides > 0)).toEqual([]);
      expect(await fromEnd(page)).toBeLessThanOrEqual(1);

      // A reply streamed a chunk per frame, with a tool row arriving under it part way.
      await sample(page);
      const prompt = row("live-user", "user", "Tell me about the lighthouse.");
      let text = "";
      for (let index = 0; index < 40; index += 1) {
        text += `${index ? "\n\n" : ""}${paragraph(index)}`;
        const answer = row("live-answer", "assistant", text, { version: index + 1, streaming: true });
        await show(page, [...opened, prompt, answer, ...(index >= 20 ? [tool("live-read")] : [])]);
        await painted(page);
      }
      await painted(page, 10);
      // Each chunk moves the view in the frame that draws it: nothing glides the new text up from
      // under the view's foot, and the view rests at its end.
      expect((await samples(page)).filter((frame) => frame.glides > 0)).toEqual([]);
      expect(await fromEnd(page)).toBeLessThanOrEqual(1);
      await page.close();
    });

    test(`${name}: scrolled up, growth leaves the reader where they are, and a send puts them at the bottom`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 560 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const opened = history(60);
      await show(page, opened);
      await painted(page, 10);
      expect(await fromEnd(page)).toBeLessThanOrEqual(1);

      // The reader scrolls up: a wheel event, then the offset it moves (headless WebKit on Linux does
      // not scroll this page for Playwright's wheel).
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -1_500, bubbles: true }));
        scroller.scrollTop -= 1_500;
      });
      await painted(page, 5);
      const left = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
      let text = "";
      for (let index = 0; index < 10; index += 1) {
        text += `${index ? "\n\n" : ""}${paragraph(index)}`;
        await show(page, [...opened, row("more-answer", "assistant", text, { version: index + 1, streaming: true })]);
        await painted(page);
      }
      await painted(page, 5);
      expect(await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop)).toBeCloseTo(
        left,
        0,
      );

      // A send while scrolled up: the view is at the bottom from the frame that draws the send on, and
      // the prompt's row and its reply arrive there.
      await sample(page);
      await page.evaluate(() => (window as unknown as { __send(): void }).__send());
      await painted(page);
      const answered = [...opened, row("more-answer", "assistant", text, { version: 11 })];
      await show(page, [...answered, row("sent-user", "user", "And then?", { pending: true })]);
      await painted(page, 2);
      await show(page, [
        ...answered,
        row("sent-user", "user", "And then?"),
        row("sent-answer", "assistant", paragraph(99), { streaming: true }),
      ]);
      await painted(page, 10);
      const sent = await samples(page);
      // The first frame may still show the scroll up: the send lands on the next painted frame.
      expect(sent.slice(1).filter((frame) => frame.fromEnd > 1)).toEqual([]);
      await page.close();
    });
  }
});
