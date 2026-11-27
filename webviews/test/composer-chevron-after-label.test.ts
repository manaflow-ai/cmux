// Every composer control that opens a menu draws its chevron a set distance after its label's words
// (Leo, 2026-11-27: "these chevrons are too close dont we have any guidelines for these yet?", on the
// location strip's folder and machine chips with the chevron touching the name). The rule is the
// transcript's (design/chat-transcript.md "Chevron after the label"), now for every label-then-chevron
// control: the chevron's ink starts between MIN_GAP and MAX_GAP px after the last visible word.
//
// Measured in Chromium over the composer gallery scenes, at a wide and a narrow pane.
// CMUX_CHEVRON_LOG=1 logs every chevron measured.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-chevron-after-label.test.ts", async () => {
  setDefaultTimeout(240_000);
  /** The nearest a chevron's ink may start after its words, in CSS px. */
  const MIN_GAP = 3;
  /** The farthest, as the transcript's rule. */
  const MAX_GAP = 8;
  const LOG = process.env.CMUX_CHEVRON_LOG === "1";
  const SCENES: { entry: string; variant: string }[] = [
    { entry: "agent-pane.composer-context", variant: "closed" },
    // The composer with a remote host: its location, folder and branch chips (the plain idle composer
    // draws no label-then-chevron control to measure).
    { entry: "agent-pane.composer-any-host", variant: "remote-rest" },
  ];
  const WIDTHS = [760, 420];
  /** The chevron glyphs a label-then-chevron control draws (ComposerPickers ChevronIcon's path). */
  const CHEVRON_PATH = "M4.6 6.3";

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer chevron after label", () => test("browser", () => {}));
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

  type Chevron = { control: string; gap: number | null };

  const measure = (page: Page): Promise<Chevron[]> =>
    page.evaluate((CHEVRON_PATH) => {
      const readable = (element: Element) => {
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
        }
        return true;
      };
      const clipped = (from: Element, top: Element, right: number) => {
        let edge = right;
        for (let node: Element | null = from; node && node !== top.parentElement; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "contents") continue;
          if (style.overflowX !== "visible" || style.textOverflow === "ellipsis")
            edge = Math.min(edge, node.getBoundingClientRect().right);
        }
        return edge;
      };
      /** The ink's left edge: the path's own box (a stroked path's ink is its box). */
      const out: Chevron[] = [];
      for (const path of document.querySelectorAll<SVGPathElement>("svg path")) {
        if (!(path.getAttribute("d") ?? "").startsWith(CHEVRON_PATH)) continue;
        if (!readable(path)) continue;
        const glyph = path.getBoundingClientRect();
        if (glyph.width === 0 || glyph.height === 0) continue;
        const control = path.closest("button, [role='button'], [role='combobox']");
        if (!control) continue;
        const middle = (glyph.top + glyph.bottom) / 2;
        let end: number | null = null;
        const walker = document.createTreeWalker(control, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const parent = node.parentElement;
          if (!parent || !node.textContent?.trim() || !readable(parent)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.top > middle || rect.bottom < middle || rect.left >= glyph.left) continue;
            const right = clipped(parent, control, rect.right);
            if (end === null || right > end) end = right;
          }
        }
        // A chevron alone (no words before it) is an icon button: not this rule's.
        if (end === null) continue;
        out.push({
          control: `${control.className} | ${(control.textContent || "").replace(/\s+/g, " ").trim().slice(0, 40)}`,
          gap: Math.round((glyph.left - end) * 100) / 100,
        });
      }
      return out;
    }, CHEVRON_PATH);

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
      const result = await measure(page);
      const out = process.env.FAST_CHECKS_OUT;
      if (out)
        await page.screenshot({
          path: path.join(out, `composer-chevrons-${key.replace(/[^\w.@-]+/g, "_")}.png`),
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
      test(`${name}: has label chevrons to measure`, async () => {
        expect((await of(scene, width)).length).toBeGreaterThan(0);
      });
      test(`${name}: every chevron's ink starts ${MIN_GAP}-${MAX_GAP}px after its words`, async () => {
        const off = (await of(scene, width)).filter(
          ({ gap }) => gap === null || gap < MIN_GAP - 0.25 || gap > MAX_GAP + 0.5,
        );
        expect(off).toEqual([]);
      });
    }
});
