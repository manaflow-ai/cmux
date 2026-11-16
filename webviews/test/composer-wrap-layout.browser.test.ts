// cmux-web-test-timeout: 600
// l10n-allow-file: typed fixture text, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { installPaintedFrames } from "./support/paintedFrames";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { UI_ANCHOR_GAP } from "../src/ui/anchor";

await requireBrowserLane("composer-wrap-layout.browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer wrap", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const layouts = [
    { entry: "agent-pane.new-tab", variant: "wrap-one-line", newTab: true, bottom: false },
    { entry: "agent-pane.composer-row", variant: "wrap-one-line", newTab: false, bottom: false },
    { entry: "agent-pane.composer-look", variant: "codex-grow-line", newTab: false, bottom: true },
  ];
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const layout of layouts)
      await warmGalleryFrame(vite, layout.entry, { browser, params: { variant: layout.variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measure = (page: Page, newTab: boolean) =>
    page.evaluate((newTab) => {
      const box = document.querySelector(newTab ? ".nt-box" : ".acpmux-composer-box")!;
      const bounds = box.getBoundingClientRect();
      const paragraph = box.querySelector(".ProseMirror > p")!;
      const text = paragraph.getBoundingClientRect();
      const field = box.querySelector<MarkdownFieldElement>(".acpmux-md-field")!;
      // Read the first glyph without moving the typing caret or changing scroll state.
      const first = document.createRange();
      first.setStart(paragraph.firstChild!, 0);
      first.setEnd(paragraph.firstChild!, 1);
      const glyph = first.getBoundingClientRect();
      const line = Number.parseFloat(getComputedStyle(paragraph).lineHeight);
      const strip = document.querySelector(newTab ? ".nt-above" : ".acpmux-composer-strip");
      const suggestions = document.querySelector(".nt-popover");
      const anchor = box.querySelector(".nt-input[data-split]") ? box.closest(".nt-composer")! : box;
      return {
        width: text.width,
        lines: Math.round((paragraph as HTMLElement).offsetHeight / line),
        line,
        top: bounds.top,
        height: bounds.height,
        firstLineTop: text.top - bounds.top,
        glyphTop: glyph.top - bounds.top,
        scrollTop: field.scrollTop,
        editorScrollTop: box.querySelector<HTMLElement>(".ProseMirror")!.scrollTop,
        moving: field.getAnimations().length > 0,
        strip: strip?.getBoundingClientRect().top,
        foot: document.querySelector(".nt-foot")?.getBoundingClientRect().top,
        suggestions: suggestions
          ? suggestions.getBoundingClientRect().top - anchor.getBoundingClientRect().bottom
          : undefined,
        devicePixelRatio: window.devicePixelRatio,
        controls: [
          ...box.querySelectorAll(
            ".acpmux-newtab-plus button, .acpmux-composer-plus button, .acpmux-mic, .acpmux-send",
          ),
        ]
          .filter((control) => control.getBoundingClientRect().width > 0)
          .map((control) => {
            const rect = control.getBoundingClientRect();
            return { left: rect.left - bounds.left, top: rect.top - bounds.top, bottom: bounds.bottom - rect.bottom };
          }),
      };
    }, newTab);

  const frame = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());
  type Measurement = Awaited<ReturnType<typeof measure>>;

  for (const layout of layouts)
    for (const density of [0.8, 0.9, 1, 1.1, 1.2])
      for (const motion of ["reduce", "off", "full"])
        test(`${layout.entry} at ${density}, ${motion}: wrapping keeps the first line and caret still`, async () => {
          const page = await browser.newPage({
            viewport: { width: 760, height: 800 },
            reducedMotion: motion === "reduce" ? "reduce" : "no-preference",
          });
          try {
            const { port } = vite.httpServer!.address() as { port: number };
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(layout.entry, { variant: layout.variant })}`);
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.evaluate(() => document.fonts.ready);
            await installPaintedFrames(page);
            const cdp = await page.context().newCDPSession(page);
            await cdp.send("Animation.enable");
            if (motion === "off")
              await page.evaluate(() => document.documentElement.setAttribute("data-cmux-motion", "off"));
            await page.evaluate((density) => {
              for (const key of ["--cmux-density-scale", "--cmux-density-text-scale", "--cmux-composer-zoom"])
                document.documentElement.style.setProperty(key, String(density));
            }, density);
            const editor = page.locator(layout.newTab ? ".nt-field .ProseMirror" : ".acpmux-composer-box .ProseMirror");
            const placeholderTop = async () => {
              await editor.fill("");
              await page.waitForFunction(
                () => document.querySelector(".acpmux-md-field")!.getAnimations().length === 0,
              );
              await frame(page);
              return page.evaluate(() => {
                const box = document.querySelector(".nt-box")!;
                return (
                  box.querySelector(".acpmux-md-placeholder")!.getBoundingClientRect().top -
                  box.getBoundingClientRect().top
                );
              });
            };
            const placeholder = layout.newTab ? await placeholderTop() : undefined;
            const fill = async (length: number, samples?: Measurement[]) => {
              await editor.fill("m".repeat(length));
              for (let step = 0; step < 600; step++) {
                const current = await measure(page, layout.newTab);
                samples?.push(current);
                if (!current.moving) break;
                await frame(page);
              }
              await frame(page);
              await frame(page);
              return measure(page, layout.newTab);
            };
            // Find the actual wrap boundary in the rendered font and density.
            let low = 1;
            let high = 512;
            expect((await fill(high)).lines).toBeGreaterThan(1);
            while (high - low > 1) {
              const middle = Math.floor((low + high) / 2);
              if ((await fill(middle)).lines === 1) low = middle;
              else high = middle;
            }
            const before = await fill(low);
            // Slow the actual wrap transitions, rather than every binary-search probe.
            await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.5 });
            const growing: Measurement[] = [];
            const after = await fill(high, growing);
            expect(before.lines).toBe(1);
            expect(after.lines).toBe(2);
            expect(before.controls.length).toBeGreaterThanOrEqual(2);
            expect(after.controls.length).toBe(before.controls.length);
            expect(Math.abs(after.width - before.width)).toBeLessThan(0.5);
            expect(Math.abs(after.firstLineTop - before.firstLineTop)).toBeLessThan(0.5);
            expect(Math.abs(after.glyphTop - before.glyphTop)).toBeLessThan(0.5);
            expect(after.moving).toBe(false);
            for (let index = 0; index < before.controls.length; index++) {
              const first = before.controls[index]!;
              const second = after.controls[index]!;
              expect(Math.abs(second.left - first.left)).toBeLessThan(0.5);
              const edge = layout.bottom ? "bottom" : "top";
              expect(Math.abs(second[edge] - first[edge])).toBeLessThan(0.5);
            }
            if (layout.newTab) {
              expect(Math.abs(before.firstLineTop - placeholder!)).toBeLessThan(0.5);
              expect(Math.abs(after.top - before.top)).toBeLessThan(0.5);
              expect(after.strip).toBe(before.strip);
              expect(Math.abs(after.height - before.height - before.line * density)).toBeLessThan(0.5);
              expect(Math.abs(after.foot! - before.foot! - (after.height - before.height))).toBeLessThan(0.5);
              expect(before.suggestions).toBeDefined();
              expect(after.suggestions).toBeDefined();
              // Floating UI rounds each placement to a device pixel. Comparing two rounded gaps
              // doubles that error; instead every placement must meet the actual anchor contract.
              for (const placed of [before, after])
                expect(Math.abs(placed.suggestions! - UI_ANCHOR_GAP)).toBeLessThanOrEqual(
                  0.5 / placed.devicePixelRatio + 1 / 64,
                );
            }
            const stable = (current: Measurement, previous: Measurement, shrinking = false) => {
              expect(current.scrollTop).toBe(0);
              expect(current.editorScrollTop).toBe(0);
              expect(Math.abs(current.firstLineTop - before.firstLineTop)).toBeLessThan(0.5);
              expect(Math.abs(current.glyphTop - before.glyphTop)).toBeLessThan(0.5);
              if (layout.newTab) {
                expect(Math.abs(current.top - before.top)).toBeLessThan(0.5);
                expect(current.strip).toBe(before.strip);
                expect(Math.abs(current.foot! - before.foot! - (current.height - before.height))).toBeLessThan(0.5);
                expect(Math.abs(current.suggestions! - UI_ANCHOR_GAP)).toBeLessThanOrEqual(
                  0.5 / current.devicePixelRatio + 1 / 64,
                );
                expect(current.height).toBeGreaterThanOrEqual(before.height - 0.5);
                expect(current.height).toBeLessThanOrEqual(after.height + 0.5);
                expect((current.height - previous.height) * (shrinking ? -1 : 1)).toBeGreaterThanOrEqual(-0.5);
              }
            };
            for (let index = 0; index < growing.length; index++) stable(growing[index]!, growing[index - 1] ?? before);
            // One more or one less character must settle on the same side each time.
            for (const length of [high + 1, high, low, low - 1, high, low]) {
              const expected = length <= low ? 1 : 2;
              expect((await fill(length)).lines).toBe(expected);
              for (let sample = 0; sample < 4; sample++) {
                await frame(page);
                const current = await measure(page, layout.newTab);
                expect(current.lines).toBe(expected);
                expect(Math.abs(current.width - before.width)).toBeLessThan(0.5);
                expect(Math.abs(current.firstLineTop - before.firstLineTop)).toBeLessThan(0.5);
                expect(Math.abs(current.glyphTop - before.glyphTop)).toBeLessThan(0.5);
              }
            }
            // Real one-character edits cross the boundary in both directions.
            for (const wrap of [true, false, true, false]) {
              const previous = await measure(page, layout.newTab);
              await editor.press("Control+End");
              await page.evaluate((newTab) => {
                const samples: { first: number; scroll: number; editorScroll: number; height: number }[] = [];
                const box = document.querySelector(newTab ? ".nt-box" : ".acpmux-composer-box")!;
                const field = box.querySelector<HTMLElement>(".acpmux-md-field")!;
                const editor = box.querySelector<HTMLElement>(".ProseMirror")!;
                const stop = window.cmuxAfterPaint(() => {
                  const paragraph = editor.querySelector("p")!;
                  const first = document.createRange();
                  first.setStart(paragraph.firstChild!, 0);
                  first.setEnd(paragraph.firstChild!, 1);
                  samples.push({
                    first: first.getBoundingClientRect().top - box.getBoundingClientRect().top,
                    scroll: field.scrollTop,
                    editorScroll: editor.scrollTop,
                    height: box.getBoundingClientRect().height,
                  });
                });
                Object.assign(window, { composerWrapFrames: { samples, stop } });
              }, layout.newTab);
              if (wrap) await page.keyboard.type("m");
              else await page.keyboard.press("Backspace");
              let last = previous;
              for (let step = 0; step < 600; step++) {
                await frame(page);
                const current = await measure(page, layout.newTab);
                stable(current, last, !wrap);
                last = current;
                if (!current.moving) break;
              }
              const painted = await page.evaluate(() => {
                const recording = (
                  window as unknown as {
                    composerWrapFrames: {
                      samples: { first: number; scroll: number; editorScroll: number; height: number }[];
                      stop(): void;
                    };
                  }
                ).composerWrapFrames;
                recording.stop();
                return recording.samples;
              });
              expect(painted.length).toBeGreaterThan(0);
              for (const sample of painted) {
                expect(sample.scroll).toBe(0);
                expect(sample.editorScroll).toBe(0);
                expect(Math.abs(sample.first - before.glyphTop)).toBeLessThan(0.5);
              }
              if (motion === "full" && after.height - before.height > 1)
                expect(
                  painted.some((sample) => sample.height > before.height + 0.5 && sample.height < after.height - 0.5),
                ).toBe(true);
              expect(last.moving).toBe(false);
              expect(last.lines).toBe(wrap ? 2 : 1);
              expect(Math.abs(last.height - (wrap ? after.height : before.height))).toBeLessThan(0.5);
            }
            if (layout.newTab) expect(Math.abs((await placeholderTop()) - placeholder!)).toBeLessThan(0.5);
            await editor.fill(Array.from({ length: 40 }, (_, index) => `line ${index + 1}`).join("\n"));
            await editor.press("Control+End");
            await page.waitForFunction(() => document.querySelector(".acpmux-md-field")!.getAnimations().length === 0);
            await frame(page);
            expect(
              await page.locator(".acpmux-md-field").evaluate((field) => field.scrollHeight > field.clientHeight),
            ).toBe(true);
            if (!layout.newTab && !layout.bottom) {
              const capped = await measure(page, false);
              for (let index = 0; index < before.controls.length; index++)
                expect(Math.abs(capped.controls[index]!.bottom - before.controls[index]!.bottom)).toBeLessThan(0.5);
            }
            await page.keyboard.type("x");
            await frame(page);
            expect(await page.locator(".acpmux-md-field").evaluate((field) => field.scrollTop)).toBeGreaterThan(0);
          } finally {
            await page.close();
          }
        });
});
