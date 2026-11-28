// cmux-web-test-timeout: 600
// A new chat's branch holds still as the draft grows. Leo, 2026-11-22 (ask-f87d5d43b4): "this still
// being at the top of the composer as it grows is the same issue" (the same as +, the mic and Send,
// which stay on the draft's last line). The branch sits in the quiet row under the draft
// (ComposerBranch, Composer.tsx), not in the location strip over the card, which rides up with it.
//
// At 360, 720 and 1100 px, with 1, 5 and 20 lines (20 is past the box's cap, so the draft scrolls
// inside it): the branch is drawn, outside the strip, below the draft's last visible line, and at
// the same place it held with one line. The strip itself rises as the draft grows, which shows the
// draft really grew.
//
// Chromium on the gallery stage (agent-pane.composer-strip, variant project), typed with Shift-Return.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("composer-branch-bottom.browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-branch-bottom: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer branch bottom", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.composer-strip";
  const VARIANT = "project";
  const WIDTHS = [360, 720, 1100];
  const LINES = [1, 5, 20];
  /** Subpixel rounding. */
  const TOLERANCE = 1;

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 720 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).first().waitFor();
    await page.locator('.acpmux-location-picker[data-kind="branch"]').first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Replaces the draft with `lines` lines, typed with Shift-Return, the caret at its end. */
  const typeLines = async (page: Page, lines: number) => {
    await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).first().click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    for (let line = 1; line <= lines; line++) {
      if (line > 1) await page.keyboard.press("Shift+Enter");
      await page.keyboard.insertText(`Line ${line}: keep retries in sync.`);
    }
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  };

  const measure = (page: Page) =>
    page.evaluate((COMPOSER_MD_FIELD) => {
      const branch = document.querySelector<HTMLElement>('.acpmux-location-picker[data-kind="branch"]');
      const strip = document.querySelector<HTMLElement>(".acpmux-composer-strip");
      const field = document.querySelector<HTMLElement>(COMPOSER_MD_FIELD);
      const rect = branch?.getBoundingClientRect();
      // The draft's last visible line, inside the field's visible area.
      let lastLine: number | null = null;
      const view = field?.getBoundingClientRect();
      if (view)
        for (const block of [...(field?.querySelectorAll(".ProseMirror > *") ?? [])].reverse()) {
          const range = document.createRange();
          range.selectNodeContents(block);
          const rects = [...range.getClientRects()].filter(
            (line) => line.height > 0 && line.top >= view.top - 1 && line.bottom <= view.bottom + 1,
          );
          const last = rects.at(-1);
          if (last) {
            lastLine = last.bottom;
            break;
          }
        }
      return {
        drawn: !!rect && rect.width > 0 && rect.height > 0,
        inStrip: !!branch && !!strip?.contains(branch),
        top: rect?.top ?? null,
        stripTop: strip?.getBoundingClientRect().top ?? null,
        lastLine,
      };
    }, COMPOSER_MD_FIELD);

  for (const width of WIDTHS)
    test(`the branch holds still under the draft at ${width} px (${LINES.join(", ")} lines)`, async () => {
      const page = await open(width);
      try {
        const seen: { lines: number; top: number; stripTop: number | null }[] = [];
        for (const lines of LINES) {
          await typeLines(page, lines);
          const at = await measure(page);
          expect({ lines, drawn: at.drawn, inStrip: at.inStrip }).toEqual({ lines, drawn: true, inStrip: false });
          expect(at.lastLine).not.toBeNull();
          // Under the draft's last visible line: the branch is in the row below it, never over it.
          expect(at.top!).toBeGreaterThanOrEqual(at.lastLine! - TOLERANCE);
          seen.push({ lines, top: at.top!, stripTop: at.stripTop });
          await page.screenshot({
            path: path.join(process.env.CMUX_TEST_ARTIFACTS ?? "/tmp", `composer-branch-bottom-${width}-${lines}.png`),
          });
        }
        const first = seen[0]!;
        for (const step of seen.slice(1))
          expect({
            lines: step.lines,
            moved: Math.abs(step.top - first.top) <= TOLERANCE ? 0 : step.top - first.top,
          }).toEqual({
            lines: step.lines,
            moved: 0,
          });
        // The draft grew: the strip over the card rose with it (the branch stayed).
        const last = seen.at(-1)!;
        if (first.stripTop !== null && last.stripTop !== null)
          expect(last.stripTop).toBeLessThan(first.stripTop - TOLERANCE);
      } finally {
        await page.close();
      }
    });
});
