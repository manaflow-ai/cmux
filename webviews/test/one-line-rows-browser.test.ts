// cmux-web-test-timeout: 300
// l10n-allow-file: probe.
// A row the transcript draws as one line shows one line: no part of a second line is painted under
// it (Leo, 2026-11-24: "is this two lines showing fixed yet? in the thuoght stuff."). A closed
// thought's line (ThoughtRow.tsx `.cv-thought__preview`) is a one-line clamp; its row's air was
// padding, and a box clips its overflow at its padding edge, so the top of the second line was drawn
// in the padding under the first. Every closed thought line, tool line and the live line, on the
// agent-pane.thought-shapes and agent-pane.live-line-burst stages at a narrow and a wide pane: each
// text line after the first must start at or past the box's clip edge, and the box at most one line
// tall plus its air.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("one-line-rows-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const THOUGHTS = "agent-pane.thought-shapes";
  const BURST = "agent-pane.live-line-burst";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [THOUGHTS, BURST], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Every one-line box in the page that paints part of a second line: its selector, its words and
  /// how far into the box's visible area the second line reaches, px.
  const secondLines = (page: Page) =>
    page.evaluate(() => {
      const found: { what: string; text: string; px: number }[] = [];
      const boxes = document.querySelectorAll<HTMLElement>(
        [
          ".cv-thought__preview:not(.is-open):not(.is-closing)",
          ".cv-tool__text",
          ".cv-worked--live .cv-shimmer__row",
        ].join(", "),
      );
      for (const box of boxes) {
        // A roll's two copies pass through the line on purpose (Thinking.tsx useRoll).
        if (box.querySelector(".cv-roll-out")) continue;
        const rect = box.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) continue;
        const style = getComputedStyle(box);
        // The clip: the box's padding edge (overflow clips there).
        const clipBottom = rect.bottom - Number.parseFloat(style.borderBottomWidth);
        const range = document.createRange();
        range.selectNodeContents(box);
        const lines = [...range.getClientRects()].filter((line) => line.height > 0 && line.width > 0);
        if (lines.length === 0) continue;
        const first = Math.min(...lines.map((line) => line.top));
        const firstBottom = Math.max(...lines.filter((line) => line.top < first + 2).map((line) => line.bottom));
        let worst = 0;
        for (const line of lines) {
          if (line.top < firstBottom - 2) continue;
          worst = Math.max(worst, clipBottom - line.top);
        }
        if (worst > 0.5)
          found.push({
            what: box.className,
            text: (box.textContent ?? "").trim().slice(0, 40),
            px: Math.round(worst * 10) / 10,
          });
      }
      return found;
    });

  const open = async (page: Page, entry: string, variant: string, width: number) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, frame: "component", width })}`);
    await page.evaluate(() => document.fonts.ready);
    await page.locator(".cv-tool, .cv-worked").first().waitFor({ state: "visible" });
    await page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );
  };

  for (const width of [360, 900])
    test(`a closed thought and a tool line paint one line, ${width} px`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      try {
        const seen: Record<string, unknown> = {};
        for (const variant of ["short", "long", "lead-run", "between-calls", "one-line", "wrapping-line"]) {
          await open(page, THOUGHTS, variant, width);
          const found = await secondLines(page);
          if (found.length) seen[variant] = found;
        }
        expect(seen).toEqual({});
      } finally {
        await page.close();
      }
    });

  test("the live line paints one line through a burst, 360 px", async () => {
    const page = await browser.newPage({ viewport: { width: 360, height: 400 } });
    try {
      await open(page, BURST, "feather", 360);
      const found: unknown[] = [];
      // Through the loop's burst and its long command (BURST_LOOP_MS 12 s; the burst from 3.5 s).
      for (let frame = 0; frame < 420; frame += 1) {
        for (const each of await secondLines(page)) found.push({ frame, ...each });
        await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())));
      }
      expect(found).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
