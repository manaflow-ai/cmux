// Every transcript disclosure chevron, and every trailing time or status at a row's end, sits on
// its row's first text line: its glyph's middle on the middle of the words it follows
// (cmux#51746: a folded thought's chevron rode a few px above its words, while the tool rows
// around it, the received line above and the skill row below, sat on theirs). One row grammar,
// single-line and cut with an ellipsis: a thought, a tool call, a skill, a message line.
//
// Measured in Chromium over the transcript gallery scenes, at a wide and a narrow pane:
// - every laid-out chevron's glyph middle lies within MAX_OFFSET px of the middle of the first text
//   line of the row it opens;
// - every trailing time or status (a thought's "4s", a call's duration) does the same.
//
// CMUX_CHEVRON_LOG=1 logs every glyph measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-chevron-vertical-center.test.ts", async () => {
  setDefaultTimeout(240_000);
  /** The farthest a glyph's middle may sit from its line's middle, in CSS px. */
  const MAX_OFFSET = 1;
  const LOG = process.env.CMUX_CHEVRON_LOG === "1";
  const SCENES: { entry: string; variant: string }[] = [
    // Folded thoughts: one cut with an ellipsis, short and long, alone and between calls.
    { entry: "agent-pane.thought-shapes", variant: "short" },
    { entry: "agent-pane.thought-shapes", variant: "long" },
    { entry: "agent-pane.thought-shapes", variant: "between-calls" },
    { entry: "agent-pane.thought-shapes", variant: "wrapping-line" },
    // Tool calls, runs, system rows and message lines.
    { entry: "agent-pane.transcript-system-rows", variant: "leo-capture" },
    { entry: "agent-pane.received-messages", variant: "collapsed" },
    { entry: "agent-pane.transcript-spacing-table", variant: "shipped" },
    { entry: "agent-pane.message-line-look", variant: "leo-capture" },
    { entry: "agent-pane.claude-desktop-organization", variant: "shared" },
  ];
  const WIDTHS = [760, 420];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript chevron vertical center", () => test("browser", () => {}));
    return;
  }
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
    for (const entry of new Set(SCENES.map((scene) => scene.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: SCENES.find((scene) => scene.entry === entry)!.variant },
      });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Glyph = {
    kind: "chevron" | "trail";
    row: string;
    /** The glyph's middle less its line's middle, in CSS px; null when no words share its row. */
    offset: number | null;
  };
  /** A row's trailing time or status at its end. */
  const TRAIL = ".cv-thought__time, .cv-tool__trail, .cv-command__meta, .cv-agent-activity__trail";

  const measure = (page: Page): Promise<Glyph[]> =>
    page.evaluate((TRAIL) => {
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
        }
        return true;
      };
      /** The text line boxes in `scope` outside `skip`, from the top. */
      const lines = (scope: Element, skip: Element) => {
        const rects: DOMRect[] = [];
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const parent = node.parentElement;
          if (!parent || !node.textContent?.trim() || skip.contains(parent) || parent.closest(TRAIL)) continue;
          if (!shown(parent)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) if (rect.width > 0 && rect.height > 0) rects.push(rect);
        }
        return rects;
      };
      /** The middle of the first line of words in the nearest box around `glyph` that has any. */
      const lineMiddle = (glyph: Element, box: DOMRect) => {
        for (let scope = glyph.parentElement; scope; scope = scope.parentElement) {
          // Words on the glyph's own row: a line's top under the glyph's bottom is a later line.
          const rects = lines(scope, glyph).filter((rect) => rect.top < box.bottom + 4 && rect.bottom > box.top - 4);
          if (rects.length > 0) {
            const top = Math.min(...rects.map((rect) => rect.top));
            const first = rects.filter((rect) => rect.top < top + 6);
            // The words' own font box: a chip's or a mono span's taller box would skew the middle.
            const middles = first.map((rect) => (rect.top + rect.bottom) / 2).sort((a, b) => a - b);
            return {
              middle: middles[Math.floor(middles.length / 2)],
              row: `${scope.className || scope.tagName} | ${(scope.textContent || "").replace(/\s+/g, " ").trim().slice(0, 50)}`,
            };
          }
          if (scope.classList.contains("acpmux-row")) break;
        }
        return null;
      };
      const out: Glyph[] = [];
      for (const chevron of document.querySelectorAll(".acpmux-row .cv-rotor")) {
        if (!shown(chevron)) continue;
        const ink = chevron.matches("svg") ? chevron.querySelector("path") : chevron.querySelector("svg path");
        if (!ink) continue;
        const box = ink.getBoundingClientRect();
        const line = lineMiddle(chevron, box);
        out.push({
          kind: "chevron",
          row: line?.row ?? chevron.className.toString(),
          offset: line ? (box.top + box.bottom) / 2 - line.middle : null,
        });
      }
      for (const trail of document.querySelectorAll(`.acpmux-row :is(${TRAIL})`)) {
        if (!shown(trail) || !trail.textContent?.trim()) continue;
        const range = document.createRange();
        range.selectNodeContents(trail);
        const box = range.getBoundingClientRect();
        if (box.height === 0) continue;
        const scope = trail.parentElement;
        if (!scope) continue;
        const rects = lines(scope, trail);
        if (rects.length === 0) continue;
        const top = Math.min(...rects.map((rect) => rect.top));
        const middles = rects
          .filter((rect) => rect.top < top + 6)
          .map((rect) => (rect.top + rect.bottom) / 2)
          .sort((a, b) => a - b);
        out.push({
          kind: "trail",
          row: `${scope.className} | ${(scope.textContent || "").replace(/\s+/g, " ").trim().slice(0, 50)}`,
          offset: (box.top + box.bottom) / 2 - middles[Math.floor(middles.length / 2)],
        });
      }
      return out;
    }, TRAIL);

  const measured = new Map<string, Glyph[]>();
  const of = async (scene: (typeof SCENES)[number], width: number) => {
    const key = `${scene.entry}#${scene.variant}@${width}`;
    const known = measured.get(key);
    if (known) return known;
    const page = await browser.newPage({ viewport: { width: width + 40, height: 1100 }, deviceScaleFactor: 2 });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(scene.entry, { variant: scene.variant, width, reducedMotion: "true" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      await page.evaluate(() => document.fonts.ready);
      await page.mouse.move(0, 0);
      await page.evaluate(() => Promise.all(document.getAnimations().map((animation) => animation.finished)));
      const result = await measure(page);
      const out = process.env.FAST_CHECKS_OUT;
      if (out)
        await page.screenshot({
          path: path.join(out, `chevron-center-${key.replace(/[^\w.@-]+/g, "_")}.png`),
          fullPage: true,
        });
      if (LOG) console.log(`GLYPHS ${key}\n${result.map((each) => JSON.stringify(each)).join("\n")}`);
      measured.set(key, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const scene of SCENES)
    for (const width of WIDTHS) {
      const name = `${scene.entry}#${scene.variant} at ${width}px`;
      test(`${name}: has chevrons to measure`, async () => {
        expect((await of(scene, width)).filter(({ kind }) => kind === "chevron").length).toBeGreaterThan(0);
      });
      test(`${name}: every chevron and trailing time sits on its words' line`, async () => {
        const off = (await of(scene, width)).filter(
          ({ offset }) => offset === null || Math.abs(offset) > MAX_OFFSET + 0.01,
        );
        expect(off).toEqual([]);
      });
    }
});
