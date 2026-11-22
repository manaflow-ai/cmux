// Caret census, input surfaces: IME composition, typing while a reply streams, and the composer
// growing (Shift+Enter, a soft wrap). Each case reads the caret after every painted frame
// (support/caretFrames.ts) and, for growth, whether the caret sits inside the field's visible box.
// Prints `CARET_FRAMES` JSON lines; `CMUX_CARET_REPORT_ONLY=1` prints without failing.
// Leo, 2026-11-22: "idk if there are other places where our caret/typing/perciee is lagging liek that".
// cmux-web-test-timeout: 900
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { FRAME_MS, installCaretTrace, judgeCaret, type CaretTrace } from "./support/caretFrames";

await requireBrowserLane("composer-caret-frames-input.browser.test.ts", async () => {
  setDefaultTimeout(900_000);
  const ENTRY = "agent-pane.composer";
  const FIELD = ".acpmux-md";
  const DRAFT = "Compare this with the previous result.";
  const reportOnly = process.env.CMUX_CARET_REPORT_ONLY === "1";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of [
      ["chromium", chromium],
      ["webkit", webkit],
    ] as const)
      browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: browsers.get("chromium")!, params: { variant: "caret-frames-draft" } });
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function stage(engine: string, variant: string, extra: Record<string, string> = {}): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 1000, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 1000, ...extra })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.waitForSelector(`${FIELD}[contenteditable='true']`);
    await installCaretTrace(page);
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "inline" }));
    await page.focus(FIELD);
    return page;
  }
  const caretAt = (page: Page, offset: number) =>
    page.evaluate((at) => {
      const field = document.querySelector(".acpmux-md-field") as unknown as {
        acpmuxMarkdownField?: { setCaret(at: number): void; focus(): void };
      };
      field.acpmuxMarkdownField!.focus();
      field.acpmuxMarkdownField!.setCaret(at);
    }, offset);
  const quiet = async (page: Page, frames: number) => {
    for (let frame = 0; frame < frames; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };

  type Box = { at: number; field: { top: number; bottom: number; height: number }; caret: { top: number; bottom: number } | null };
  /** Starts the caret trace and a per-frame record of the field's box beside the caret. */
  const begin = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __boxes: unknown[]; __stopBoxes?: () => void };
      w.__stopBoxes?.();
      w.__boxes = [];
      window.cmuxCaretTrace!.start(".acpmux-md");
      w.__stopBoxes = window.cmuxAfterPaint((at) => {
        const field = document.querySelector(".acpmux-md-field")!.getBoundingClientRect();
        const truth = window.cmuxCaretTrace!.read(".acpmux-md").truth;
        w.__boxes.push({
          at,
          field: { top: field.top, bottom: field.bottom, height: field.height },
          caret: truth ? { top: truth.top, bottom: truth.bottom } : null,
        });
      });
    });
  const end = async (page: Page) => {
    const result = await page.evaluate(() => {
      const w = window as unknown as { __boxes: unknown[]; __stopBoxes?: () => void };
      w.__stopBoxes?.();
      return { trace: window.cmuxCaretTrace!.stop(), boxes: w.__boxes };
    });
    const trace = result.trace as CaretTrace;
    const boxes = (result.boxes as Box[]).filter((box) => box.at >= trace.inputAt - FRAME_MS);
    // A caret outside the field's visible box (more than 1 px) is clipped: not in place.
    const clipped = boxes
      .filter((box) => box.caret && (box.caret.bottom > box.field.bottom + 1 || box.caret.top < box.field.top - 1))
      .map((box) => ({
        afterInputMs: Math.round(box.at - trace.inputAt),
        overPx: Math.round(Math.max(box.caret!.bottom - box.field.bottom, box.field.top - box.caret!.top) * 10) / 10,
      }));
    const heights = boxes.map((box) => box.field.height);
    return { trace, verdict: judgeCaret(trace), clipped, grew: Math.max(...heights, 0) - Math.min(...heights, 1e9) };
  };
  const round = (value: number | null) => (value === null ? null : Math.round(value * 10) / 10);
  const report = (row: Record<string, unknown>) => console.log(`CARET_FRAMES ${JSON.stringify(row)}`);

  for (const engine of ["chromium", "webkit"]) {
    // 1. IME composition.
    test(`${engine}: IME composition`, async () => {
      const page = await stage(engine, "caret-frames-draft");
      try {
        await caretAt(page, DRAFT.length);
        const steps: { step: string; wrong: number; ms: number | null }[] = [];
        let session: import("playwright").CDPSession | undefined;
        if (engine === "chromium") session = await page.context().newCDPSession(page);
        const composed = ["に", "にほ", "にほん", "にほんご"];
        const run = async (step: string, act: () => Promise<void>) => {
          await begin(page);
          await act();
          await quiet(page, 6);
          const { verdict } = await end(page);
          steps.push({ step, wrong: verdict.wrongFrames.length, ms: round(verdict.inputToCaretMs) });
        };
        for (let index = 0; index < composed.length; index++) {
          const text = composed[index]!;
          await run(index === 0 ? "start" : `update${index}`, async () => {
            if (session) await session.send("Input.imeSetComposition", { text, selectionStart: text.length, selectionEnd: text.length });
            else
              // WebKit cannot be driven with a real IME in Playwright: events plus the DOM edit it makes.
              await page.evaluate((value) => {
                const field = document.querySelector(".acpmux-md")!;
                if (value.length === 1) field.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
                document.execCommand("insertText", false, value.slice(-1));
                field.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data: value }));
              }, text);
          });
        }
        await run("commit", async () => {
          if (session) await session.send("Input.insertText", { text: composed.at(-1)! });
          else
            await page.evaluate((value) => {
              document.querySelector(".acpmux-md")!.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: value }));
            }, composed.at(-1)!);
        });
        report({
          surface: "ime",
          engine,
          driver: session ? "CDP Input.imeSetComposition" : "synthetic composition events + execCommand (no real IME in WebKit)",
          wrongFrames: steps.reduce((sum, step) => sum + step.wrong, 0),
          inputToCaretMs: Math.max(...steps.map((step) => step.ms ?? 0)),
          steps,
        });
        if (!reportOnly) {
          expect(steps.reduce((sum, step) => sum + step.wrong, 0)).toBe(0);
          expect(Math.max(...steps.map((step) => step.ms ?? 0))).toBeLessThanOrEqual(FRAME_MS + 1);
        }
      } finally {
        await page.close();
      }
    });

    // 2. Typing while a reply streams (and the same with nothing streaming, as the baseline).
    for (const streaming of [false, true])
      test(`${engine}: typing ${streaming ? "while a reply streams" : "idle (baseline)"}`, async () => {
        const page = await stage(engine, "caret-frames-draft", streaming ? { script: "streaming" } : {});
        try {
          await caretAt(page, DRAFT.length);
          const textBefore = await page.evaluate(() => document.body.innerText.length);
          const times: number[] = [];
          let wrong = 0;
          for (let index = 0; index < 30; index++) {
            await begin(page);
            await page.keyboard.type(String.fromCharCode(97 + (index % 26)));
            await quiet(page, 4);
            const { verdict } = await end(page);
            wrong += verdict.wrongFrames.length;
            times.push(verdict.inputToCaretMs ?? 0);
          }
          const textAfter = await page.evaluate(() => document.body.innerText.length);
          times.sort((a, b) => a - b);
          report({
            surface: streaming ? "typing-while-streaming" : "typing-idle",
            engine,
            wrongFrames: wrong,
            inputToCaretMs: round(times.at(-1)!),
            p50Ms: round(times[times.length >> 1]!),
            keys: times.length,
            transcriptGrewChars: textAfter - textBefore,
          });
          if (!reportOnly) {
            expect(wrong).toBe(0);
            expect(times.at(-1)!).toBeLessThanOrEqual(FRAME_MS + 1);
          }
        } finally {
          await page.close();
        }
      });

    // 3. Growth: Shift+Enter and a soft wrap.
    for (const how of ["shift-enter", "soft-wrap", "shift-enter-x3"])
      test(`${engine}: growth ${how}`, async () => {
        const page = await stage(engine, "caret-frames-draft");
        try {
          await caretAt(page, DRAFT.length);
          let result: Awaited<ReturnType<typeof end>> | undefined;
          if (how === "shift-enter") {
            await begin(page);
            await page.keyboard.press("Shift+Enter");
            await quiet(page, 40);
            result = await end(page);
          } else if (how === "shift-enter-x3") {
            // Repeated lines while the field still moves (a retarget each time).
            await begin(page);
            for (let index = 0; index < 3; index++) {
              await page.keyboard.press("Shift+Enter");
              await page.keyboard.type("b");
            }
            await quiet(page, 40);
            result = await end(page);
          } else {
            // Types words until the field grows a line, one traced key at a time.
            for (let index = 0; index < 400 && !result; index++) {
              await begin(page);
              await page.keyboard.type(index % 6 === 5 ? " " : "w");
              await quiet(page, 3);
              const attempt = await end(page);
              if (attempt.grew > 4) {
                await quiet(page, 40);
                result = attempt;
              }
            }
            if (!result) throw new Error("the field never wrapped");
          }
          const { verdict, clipped, grew } = result!;
          report({
            surface: `growth-${how}`,
            engine,
            wrongFrames: verdict.wrongFrames.length,
            inputToCaretMs: round(verdict.inputToCaretMs),
            clippedFrames: clipped.length,
            clippedMaxPx: clipped.length ? Math.max(...clipped.map((frame) => frame.overPx)) : 0,
            clippedFirst: clipped.slice(0, 3),
            fieldGrewPx: round(grew),
            firstWrong: verdict.wrongFrames.slice(0, 2),
          });
          if (!reportOnly) {
            expect(verdict.wrongFrames).toEqual([]);
            expect(clipped).toEqual([]);
          }
        } finally {
          await page.close();
        }
      });
  }
});
