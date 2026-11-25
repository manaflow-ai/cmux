// Leo, 2026-11-22: "when im pasting attachments or whatever, there's a breif moment where i see the
// caret at the beginning of the composer after the preview for the attachment has already shown up,
// and then it doesn't follow as fast, it follows with a delay. we can't have that."
//
// After a screenshot is pasted between words, the caret stands after its chip on every painted frame
// the chip has width: never at the line's start beside a chip that has already drawn. The caret on a
// line with an attachment is the field's drawn bar (composer/inlineCaret.ts); the chip's NodeView is
// empty when the caret is first placed and its preview fills in on a later render, so the bar has to
// follow the chip's size as it changes, in the frame it changes.
//
// Each case pastes (as the Edit menu's Paste does) and samples every painted frame
// (support/paintedFrames.ts) from the paste until the preview has loaded and the person typed on:
// - the read answers at once;
// - the read is held, so the chip's loading box draws first and its preview later.
//
// The page is the pane's dev entry with the in-page mock daemon. Real Chromium from Playwright; CI
// fails the file when it cannot launch (requireBrowserLane).
// cmux-web-test-timeout: 600
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

/// One painted frame: the chip's box, and the caret shown (the drawn bar on a line with an
/// attachment, else the native caret's place), in viewport px.
type Frame = {
  chip?: { left: number; right: number };
  caret?: number;
  drawn: boolean;
};
type ProbeWindow = Window & {
  __frames?: Frame[];
  __stopFrames?: () => void;
  __holdReads?: boolean;
  __releaseReads?: () => void;
  __shot?: File;
};

await requireBrowserLane("composer-paste-caret-follows.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-paste-caret-follows: skipping (run `bunx playwright install chromium`)");
    describe.skip("pasted chip caret", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: {
        port: 0,
        host: "127.0.0.1",
        strictPort: false,
        watch: { ignored: () => true },
      },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function openPane(): Promise<Page> {
    const page = await browser!.newPage({
      viewport: { width: 900, height: 640 },
    });
    await page.addInitScript(() => {
      const state = window as ProbeWindow;
      let release = () => {};
      const reads = new Promise<void>((resolve) => (release = resolve));
      state.__releaseReads = () => {
        state.__holdReads = false;
        release();
      };
      const held = () => (state.__holdReads ? reads : Promise.resolve());
      const buffer = Blob.prototype.arrayBuffer;
      Blob.prototype.arrayBuffer = async function (this: Blob) {
        if (this.size > 4096) await held();
        return buffer.call(this);
      };
      const post = Worker.prototype.postMessage as (this: Worker, ...args: unknown[]) => void;
      Worker.prototype.postMessage = function (this: Worker, ...args: unknown[]) {
        if (!state.__holdReads) return post.apply(this, args);
        void held().then(() => post.apply(this, args));
      } as Worker["postMessage"];
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, {
      timeout: 120_000,
    });
    await installPaintedFrames(page);
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.selectSession("mock-session"));
    await page.locator(COMPOSER_EDITOR).waitFor();
    return page;
  }

  const makeShot = (page: Page) =>
    page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 1440;
      canvas.height = 900;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#1b1c20";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#d6d7db";
      context.fillRect(40, 40, 600, 200);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      (window as ProbeWindow).__shot = new File([blob], "Screenshot.png", {
        type: "image/png",
      });
    });

  /// Samples every painted frame, then pastes the screenshot at the caret in the same task.
  const pasteSampling = (page: Page) =>
    page.evaluate((prompt) => {
      const state = window as ProbeWindow;
      const frames: Frame[] = [];
      state.__frames = frames;
      state.__stopFrames = window.cmuxAfterPaint(() => {
        const field = document.querySelector(prompt);
        if (!field) return true;
        const node = [...field.querySelectorAll<HTMLElement>("[data-inline-attachment]")]
          .map((element) => element.getBoundingClientRect())
          .find((rect) => rect.width > 0);
        const line = field.querySelector(".acpmux-md-caret-line");
        const bar = document.querySelector<HTMLElement>(".acpmux-md-caret");
        let caret: number | undefined;
        if (line) {
          if (bar && !bar.hidden) caret = bar.getBoundingClientRect().left;
        } else {
          const selection = document.getSelection();
          const rects = selection?.rangeCount ? selection.getRangeAt(0).getClientRects() : undefined;
          const rect = rects?.[rects.length - 1];
          if (rect) caret = rect.left;
        }
        frames.push({
          chip: node && { left: node.left, right: node.right },
          caret,
          drawn: !!line,
        });
        return true;
      });
      const data = new DataTransfer();
      data.items.add(state.__shot!);
      const paste = new ClipboardEvent("paste", {
        clipboardData: data,
        bubbles: true,
        cancelable: true,
      });
      if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
      document.querySelector(prompt)!.dispatchEvent(paste);
    }, COMPOSER_EDITOR);

  const stopFrames = (page: Page) =>
    page.evaluate(() => {
      const state = window as ProbeWindow;
      state.__stopFrames?.();
      return state.__frames!;
    });

  /// Every frame whose chip has width and whose caret is missing or before the chip's right edge.
  const behind = (frames: Frame[]) =>
    frames.flatMap((frame, index) =>
      frame.chip && (frame.caret === undefined || frame.caret < frame.chip.right - 1)
        ? [
            `frame ${index}: chip ${frame.chip.left.toFixed(1)}..${frame.chip.right.toFixed(1)}, caret ${frame.caret?.toFixed(1) ?? "none"}`,
          ]
        : [],
    );

  for (const hold of [false, true]) {
    test(`the caret follows a pasted screenshot's chip in the frame it draws (${hold ? "held read" : "read at once"})`, async () => {
      const page = await openPane();
      await page.locator(COMPOSER_EDITOR).click();
      await page.keyboard.type("compare ");
      await makeShot(page);
      if (hold) await page.evaluate(() => ((window as ProbeWindow).__holdReads = true));
      await pasteSampling(page);
      await page.waitForFunction(
        (prompt) => !!document.querySelector(prompt)?.querySelector("[data-inline-attachment]"),
        COMPOSER_EDITOR,
      );
      await page.keyboard.type("with", { delay: 20 });
      if (hold) await page.evaluate(() => (window as ProbeWindow).__releaseReads!());
      await page.waitForFunction(
        (prompt) => !!document.querySelector(prompt)?.querySelector("[data-inline-attachment] img"),
        COMPOSER_EDITOR,
        { timeout: 30_000 },
      );
      for (let frame = 0; frame < 10; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      await page.keyboard.type(" the old one", { delay: 20 });
      await page.evaluate(() => window.cmuxPaintFrame());
      const frames = await stopFrames(page);
      const late = behind(frames);
      console.log(
        `PASTE-CARET ${hold ? "held" : "at-once"}: frames ${frames.length}, with chip ${frames.filter((frame) => frame.chip).length}, caret behind ${late.length}`,
      );
      expect(frames.filter((frame) => frame.chip).length).toBeGreaterThan(0);
      expect(late).toEqual([]);
      await page.close();
    });
  }
});
