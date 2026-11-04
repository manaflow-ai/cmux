// Every transcript disclosure chevron sits right after its label's words, the way ChatGPT draws
// "Worked for 11s ⌄" (Leo, 2026-11-03: "this how chatgpt does their chevrons"): small, muted,
// pointing down while closed and up while open, never parked at the row's far edge. A label cut with
// an ellipsis keeps its chevron right after the visible words. design/chat-transcript.md "Chevron
// after the label".
//
// Measured in Chromium over the transcript gallery scenes, at a wide and a narrow pane:
// - every laid-out chevron (an opened group's inner steps too, whose chevron shows on hover) starts
//   within MAX_GAP px of the right edge of the last visible words before it on its line;
// - every chevron's glyph is wider than tall (it points down or up, never right).
//
// CMUX_CHEVRON_LOG=1 logs every chevron measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-chevron-after-label.test.ts", async () => {
  setDefaultTimeout(240_000);
  /** The farthest a chevron's glyph may start after its words, in CSS px. */
  const MAX_GAP = 8;
  const LOG = process.env.CMUX_CHEVRON_LOG === "1";
  const SCENES: { entry: string; variant: string }[] = [
    { entry: "agent-pane.transcript-system-rows", variant: "leo-capture" },
    { entry: "agent-pane.received-messages", variant: "collapsed" },
    { entry: "agent-pane.received-messages", variant: "level-1" },
    { entry: "agent-pane.received-messages", variant: "level-2" },
    { entry: "agent-pane.transcript-spacing-table", variant: "shipped" },
    { entry: "agent-pane.transcript-spacing-table", variant: "peer-lines" },
    { entry: "agent-pane.transcript-chevron-after-label", variant: "chatgpt" },
    // Message rows on one line (Leo, 2026-11-03: "the weird chevron spacing thing"): a send with a
    // count, SendMessage rows to long names, a bot's received line and a received pair.
    { entry: "agent-pane.message-line-look", variant: "leo-capture" },
    { entry: "agent-pane.message-line-look", variant: "single" },
    // An opened lead thought: "Thought for 6s" and its chevron right after it (cmux#27896 parked it
    // at the row's far edge).
    { entry: "agent-pane.claude-desktop-organization", variant: "shared" },
  ];
  const WIDTHS = [760, 420];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript chevron after label", () => test("browser", () => {}));
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

  type Chevron = {
    row: string;
    gap: number | null;
    /** Whether the words it follows are a trailing status or duration, not the label. */
    trail: boolean;
    width: number;
    height: number;
    edge: number;
  };
  /** A row's trailing status or duration column, which goes after the chevron. */
  const TRAIL = ".cv-tool__trail, .cv-command__meta, .cv-agent-activity__trail, .cv-subagent-done__trail";

  const measure = (page: Page): Promise<Chevron[]> =>
    page.evaluate((TRAIL) => {
      const laidOut = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement)
          if (getComputedStyle(node).display === "none") return false;
        return true;
      };
      const readable = (element: Element) => {
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
        }
        return true;
      };
      /** The right edge `right` is clipped to by the clipping boxes between `from` and `top`. */
      const clipped = (from: Element, top: Element, right: number) => {
        let edge = right;
        for (let node: Element | null = from; node && node !== top.parentElement; node = node.parentElement) {
          const style = getComputedStyle(node);
          // A `display: contents` box draws nothing and clips nothing (a message line's sentence).
          if (style.display === "contents") continue;
          if (style.overflowX !== "visible" || style.textOverflow === "ellipsis")
            edge = Math.min(edge, node.getBoundingClientRect().right);
        }
        return edge;
      };
      /** The right edge of the last readable words before `glyph` on its line, inside `scope`. */
      const wordsEnd = (scope: Element, glyph: DOMRect, chevron: Element) => {
        const middle = (glyph.top + glyph.bottom) / 2;
        let end: number | null = null;
        let trail = false;
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const parent = node.parentElement;
          if (!parent || !node.textContent?.trim() || chevron.contains(parent) || !readable(parent)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.top > middle || rect.bottom < middle || rect.left >= glyph.left) continue;
            const right = clipped(parent, scope, rect.right);
            if (right <= glyph.left + 1 && (end === null || right > end)) {
              end = right;
              trail = parent.closest(TRAIL) !== null;
            }
          }
        }
        return end === null ? null : { end, trail };
      };
      const out: Chevron[] = [];
      for (const chevron of document.querySelectorAll(".acpmux-row .cv-rotor")) {
        if (!laidOut(chevron)) continue;
        const path = chevron.matches("svg") ? chevron.querySelector("path") : chevron.querySelector("svg path");
        if (!path) continue;
        const glyph = path.getBoundingClientRect();
        let gap: number | null = null;
        let trail = false;
        let row: Element = chevron;
        // The nearest box around the chevron that holds words before it on its line: its own toggle,
        // or the line a chevron-only toggle sits on.
        for (let scope = chevron.parentElement; scope; scope = scope.parentElement) {
          row = scope;
          const words = wordsEnd(scope, glyph, chevron);
          if (words !== null) {
            gap = glyph.left - words.end;
            trail = words.trail;
            break;
          }
          if (scope.classList.contains("acpmux-row")) break;
        }
        const line = chevron.closest(".acpmux-row")!.getBoundingClientRect();
        out.push({
          row: `${row.className || row.tagName} | ${(row.textContent || "").replace(/\s+/g, " ").trim().slice(0, 50)}`,
          gap,
          trail,
          width: glyph.width,
          height: glyph.height,
          edge: line.right - glyph.right,
        });
      }
      return out;
    }, TRAIL);

  const measured = new Map<string, Chevron[]>();
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
      // A fast-checks run keeps a still of every scene it measured.
      const out = process.env.FAST_CHECKS_OUT;
      if (out)
        await page.screenshot({
          path: path.join(out, `chevrons-${key.replace(/[^\w.@-]+/g, "_")}.png`),
          fullPage: true,
        });
      if (LOG) console.log(`CHEVRONS ${key}\n${result.map((each) => JSON.stringify(each)).join("\n")}`);
      measured.set(key, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const scene of SCENES)
    for (const width of WIDTHS) {
      const name = `${scene.entry}#${scene.variant} at ${width}px`;
      test(`${name}: has disclosure chevrons to measure`, async () => {
        expect((await of(scene, width)).length).toBeGreaterThan(0);
      });
      test(`${name}: every chevron starts within ${MAX_GAP}px after its words`, async () => {
        // After its label's words, never after a trailing status or duration at the line's end.
        const far = (await of(scene, width)).filter(
          ({ gap, trail }) => trail || gap === null || gap < -0.5 || gap > MAX_GAP + 0.5,
        );
        expect(far).toEqual([]);
      });
      test(`${name}: every chevron points down or up, never right`, async () => {
        const sideways = (await of(scene, width)).filter(({ width: wide, height }) => wide <= height);
        expect(sideways).toEqual([]);
      });
    }
});
