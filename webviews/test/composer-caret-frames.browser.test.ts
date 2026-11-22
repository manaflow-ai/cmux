// The caret is never out of place for a frame after an edit in the composer, and reaches its final
// place within a frame of the input (or, for an attachment, in the frame the attachment takes its
// size). Leo, 2026-11-22: "when im pasting attachments or whatever, there's a breif moment where i
// see the caret at the beginning of the composer after the preview for the attachment has already
// shown up, and then it doesn't follow as fast, it follows with a delay. we can't have that."
//
// Each case edits the real composer in the gallery (agent-pane.composer caret-frames-*), reads the
// caret after every painted frame (support/caretFrames.ts) and prints one `CARET_FRAMES` JSON line
// per case and engine, the census numbers. `CMUX_CARET_REPORT_ONLY=1` prints without failing (a
// before run on the old code).
// cmux-web-test-timeout: 600
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { FRAME_MS, installCaretTrace, judgeCaret, type CaretTrace } from "./support/caretFrames";

await requireBrowserLane("composer-caret-frames.browser.test.ts", async () => {
  setDefaultTimeout(600_000);
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
    await warmGalleryFrame(vite, ENTRY, {
      browser: browsers.get("chromium")!,
      params: { variant: "caret-frames-draft" },
    });
  }, 300_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function stage(engine: string, variant: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 1000, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 1000 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.waitForSelector(`${FIELD}[contenteditable='true']`);
    await installCaretTrace(page);
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "inline" }));
    await page.focus(FIELD);
    return page;
  }

  /** Puts the caret `offset` characters into the prompt's text (the end when past it). */
  const caretAt = (page: Page, offset: number) =>
    page.evaluate((at) => {
      const field = document.querySelector(".acpmux-md-field") as unknown as {
        acpmuxMarkdownField?: { setCaret(at: number): void; focus(): void };
      };
      field.acpmuxMarkdownField!.focus();
      field.acpmuxMarkdownField!.setCaret(at);
    }, offset);

  /** Pastes (or drops) `count` screenshots on the prompt, as WebKit hands a paste of files to the page.
   *  `big`: a full-screen Retina capture (3456×2234, noisy), whose picture decodes frames after its
   *  tile took its size from the header, as Leo's screenshots do. */
  const giveImages = (page: Page, how: "paste" | "drop", count = 1, big = false) =>
    page.evaluate(
      async ({ how, count, big }) => {
        const files = await Promise.all(
          Array.from({ length: count }, async (_, index) => {
            const canvas = document.createElement("canvas");
            canvas.width = big ? 3456 : 320;
            canvas.height = big ? 2234 : 180;
            const drawing = canvas.getContext("2d")!;
            drawing.fillStyle = index ? "#e0a84f" : "#5783b5";
            drawing.fillRect(0, 0, canvas.width, canvas.height);
            if (big) {
              let seed = 7 + index;
              const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
              const noise = drawing.getImageData(0, 0, canvas.width, canvas.height);
              for (let at = 0; at < noise.data.length; at += 4) {
                noise.data[at] = random() * 255;
                noise.data[at + 1] = random() * 255;
                noise.data[at + 2] = random() * 255;
              }
              drawing.putImageData(noise, 0, 0);
            }
            const blob = await new Promise<Blob>((resolve) => canvas.toBlob((value) => resolve(value!), "image/png"));
            return new File([blob], `Screenshot ${index + 1}.png`, { type: "image/png" });
          }),
        );
        const field = document.querySelector(".acpmux-md")!;
        window.cmuxCaretTrace!.start(".acpmux-md");
        if (how === "paste") {
          const paste = new Event("paste", { bubbles: true, cancelable: true });
          Object.defineProperty(paste, "clipboardData", { value: { files, types: ["Files"], getData: () => "" } });
          window.cmuxCaretTrace!.input();
          field.dispatchEvent(paste);
        } else {
          const drop = new Event("drop", { bubbles: true, cancelable: true });
          Object.defineProperty(drop, "dataTransfer", { value: { files, types: ["Files"] } });
          window.cmuxCaretTrace!.input();
          field.dispatchEvent(drop);
        }
      },
      { how, count, big },
    );

  /** Waits until every attachment in the text is its ready chip with its picture, then a few frames. */
  const settledChips = async (page: Page, count: number) => {
    await page.waitForFunction(
      (want) =>
        document.querySelectorAll(".acpmux-md [data-inline-attachment] .acpmux-md-inline-chip[data-state='ready'] img")
          .length >= want,
      count,
      { timeout: 30_000 },
    );
    await page.waitForFunction(
      () => document.querySelectorAll("img").length > 0 && [...document.images].every((image) => image.complete),
    );
    for (let frame = 0; frame < 20; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };
  const quietFrames = async (page: Page, frames = 20) => {
    for (let frame = 0; frame < frames; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  };

  /** Holds each picture's `load` back from the field until the trace ends: a big capture's decode in
   *  the app comes frames after its tile took its size, and only the chip's own change may move the
   *  caret then (before, the drawn caret waited for that `load`). */
  const holdLoads = (page: Page) =>
    page.evaluate(() => {
      const hold = (event: Event) => {
        if (event.target instanceof HTMLImageElement && event.target.closest(".acpmux-md")) event.stopPropagation();
      };
      addEventListener("load", hold, { capture: true });
    });

  type Case = {
    name: string;
    variant: "caret-frames-empty" | "caret-frames-draft";
    /** Sets up, makes the edit and waits until it settled. */
    run(page: Page): Promise<void>;
    /** A lag measured and printed but not failed on yet, with its cause; its owner is named beside it. */
    known?: string;
  };
  const CASES: Case[] = [
    {
      name: "paste image, empty prompt",
      variant: "caret-frames-empty",
      async run(page) {
        await giveImages(page, "paste");
        await settledChips(page, 1);
      },
    },
    {
      name: "paste big screenshot, empty prompt",
      variant: "caret-frames-empty",
      async run(page) {
        await giveImages(page, "paste", 1, true);
        await settledChips(page, 1);
      },
    },
    {
      name: "paste big screenshot beside an image",
      variant: "caret-frames-empty",
      async run(page) {
        await giveImages(page, "paste");
        await settledChips(page, 1);
        await page.evaluate(() => window.cmuxCaretTrace!.stop());
        await giveImages(page, "paste", 1, true);
        await settledChips(page, 2);
      },
    },
    {
      name: "paste image, empty prompt, picture load late",
      variant: "caret-frames-empty",
      async run(page) {
        await holdLoads(page);
        await giveImages(page, "paste");
        await settledChips(page, 1);
      },
    },
    {
      name: "paste big screenshot beside an image, picture load late",
      variant: "caret-frames-empty",
      async run(page) {
        await giveImages(page, "paste");
        await settledChips(page, 1);
        await page.evaluate(() => window.cmuxCaretTrace!.stop());
        await holdLoads(page);
        await giveImages(page, "paste", 1, true);
        await settledChips(page, 2);
      },
    },
    {
      name: "paste image, end of text, picture load late",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await holdLoads(page);
        await giveImages(page, "paste");
        await settledChips(page, 1);
      },
    },
    {
      name: "paste image, end of text",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await giveImages(page, "paste");
        await settledChips(page, 1);
      },
    },
    {
      name: "paste image, mid text",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, "Compare this".length);
        await giveImages(page, "paste");
        await settledChips(page, 1);
      },
    },
    {
      name: "paste second image beside the first",
      variant: "caret-frames-empty",
      async run(page) {
        // The first paste, outside the trace: then the line is a chip's height already, so the
        // second chip widens the line and no longer grows the field.
        await giveImages(page, "paste");
        await settledChips(page, 1);
        await page.evaluate(() => window.cmuxCaretTrace!.stop());
        await giveImages(page, "paste");
        await settledChips(page, 2);
      },
    },
    {
      name: "paste two images at once",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await giveImages(page, "paste", 2);
        await settledChips(page, 2);
      },
    },
    {
      name: "drop image",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await giveImages(page, "drop");
        await settledChips(page, 1);
      },
    },
    {
      name: "paste text",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await page.evaluate(() => {
          window.cmuxCaretTrace!.start(".acpmux-md");
          const transfer = new DataTransfer();
          transfer.setData("text/plain", " and the one before it");
          const paste = new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer });
          window.cmuxCaretTrace!.input();
          document.querySelector(".acpmux-md")!.dispatchEvent(paste);
        });
        await quietFrames(page);
      },
    },
    {
      name: "type a character",
      variant: "caret-frames-draft",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await page.evaluate(() => window.cmuxCaretTrace!.start(".acpmux-md"));
        await page.keyboard.type("x");
        await quietFrames(page);
      },
    },
    {
      name: "type a character beside an image",
      variant: "caret-frames-empty",
      async run(page) {
        await giveImages(page, "paste");
        await settledChips(page, 1);
        await page.evaluate(() => window.cmuxCaretTrace!.stop());
        await page.evaluate(() => window.cmuxCaretTrace!.start(".acpmux-md"));
        await page.keyboard.type("x");
        await quietFrames(page);
      },
    },
    {
      name: "type to a second line",
      variant: "caret-frames-draft",
      // Measured, not yet gated: the field grows to the new line over frames
      // (composer/fieldGrowth.ts), and the caret on the new line stands below the field's box for
      // 1-2 of them (chromium 2 frames, 36.6 ms; webkit 1 frame, 78 ms; fleet run 45008372497).
      // Owner: the composer geometry lane (leo/composer-geometry), fieldGrowth.ts and caretInView.ts.
      known: "the field's growth clips the caret on the new line for 1-2 frames",
      async run(page) {
        await caretAt(page, DRAFT.length);
        await page.evaluate(() => window.cmuxCaretTrace!.start(".acpmux-md"));
        await page.keyboard.press("Shift+Enter");
        await quietFrames(page, 40);
      },
    },
  ];

  for (const engine of ["chromium", "webkit"])
    for (const each of CASES)
      test(`${engine}: ${each.name}: the caret is in place every frame and settles in time`, async () => {
        const page = await stage(engine, each.variant);
        try {
          await each.run(page);
          const trace = (await page.evaluate(() => window.cmuxCaretTrace!.stop())) as CaretTrace;
          const verdict = judgeCaret(trace);
          console.log(
            `CARET_FRAMES ${JSON.stringify({
              engine,
              case: each.name,
              wrongFrames: verdict.wrongFrames.length,
              inputToCaretMs: verdict.inputToCaretMs === null ? null : Math.round(verdict.inputToCaretMs * 10) / 10,
              inputToChipsMs: verdict.inputToChipsMs === null ? null : Math.round(verdict.inputToChipsMs * 10) / 10,
              settleMs: verdict.settleMs === null ? null : Math.round(verdict.settleMs * 10) / 10,
              unpaintedFrames: verdict.unpaintedFrames,
              framesToSettle: verdict.framesToSettle,
              frames: trace.frames.length,
              firstWrong: verdict.wrongFrames.slice(0, 3),
            })}`,
          );
          if (reportOnly || each.known) return;
          expect(trace.frames.length).toBeGreaterThan(0);
          expect(verdict.wrongFrames).toEqual([]);
          expect(verdict.inputToCaretMs).not.toBeNull();
          // In place in the input's first painted frame: within a frame of it (and a ms for the clock).
          // With an attachment, no later than the frame its chip took its width in: an engine that
          // paints no frame while it reads a big picture's header (WebKit, ~400 ms for a 3456x2234
          // screenshot) paints the chip and the caret beside it in the same first frame.
          const bound = Math.max(FRAME_MS, verdict.inputToChipsMs ?? 0) + 1;
          expect(verdict.inputToCaretMs!).toBeLessThanOrEqual(bound);
        } finally {
          await page.close();
        }
      });
});
