// The composer's controls share one grid (Leo's report, 2026-10-27: "a ton of alignment issues"):
//   - the box's row: + (its button and glyph), the prompt's placeholder line and the mic (and Send
//     when a draft shows it) share one vertical center, and each glyph sits in the center of its button;
//   - the box's columns: + sits as far from the box's left edge as the mic's glyph sits from its right
//     edge (8 px and 8 px: + and the mic glyphs' centers both sit 22 px in), and the placeholder
//     starts one 8 px lead gap after the + button, so the caret lines up with that column (Leo
//     2026-10-31: "composer still looks like shit with the + spacing indent to the text");
//   - the quiet row under the box: the permission mode (button, text, shield), the model (button,
//     text) and the context ring (the spinner before usage is reported) share one vertical center.
// Measured in Chromium on the gallery's composer row (agent-pane.composer-row, the idle chat with an
// empty prompt), light and dark, at a normal and a narrow pane. Real Chromium from Playwright; CI
// fails the file when it cannot launch (requireBrowserLane). The measurement and its numbers come
// from composer-alignment-measure.test.ts.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { measureComposerAlignment, type Center, type ComposerAlignment } from "./support/composerAlignment";

await requireBrowserLane("composer-alignment-centers.test.ts", async () => {
  /** Half a pixel: the subpixel rounding a centered 28 px control and its 16 px glyph can show. */
  const TOLERANCE = 0.5;
  /** The placeholder starts one lead gap (--acpmux-composer-lead-gap, 8 px) after the + button's box. */
  const TEXT_GAP = 8;
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-alignment-centers: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer alignment centers", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-row", { variant, theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-row", { browser, params: { variant: "claude-auto" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measure = async (width: number, scheme: string): Promise<ComposerAlignment> => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL("claude-auto", scheme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-composer-box .acpmux-md-placeholder").first().waitFor();
    await page.locator(".acpmux-composer-foot .acpmux-model .acpmux-picker-button").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const result = await page.evaluate(measureComposerAlignment);
    await page.close();
    return result;
  };

  /** The problems one measurement shows, each named with its numbers. */
  const problems = (m: ComposerAlignment): string[] => {
    const out: string[] = [];
    const off = (a: number, b: number) => Math.abs(a - b) > TOLERANCE;
    const f = (n: number) => n.toFixed(2);
    const plus = m.plusButton;
    const plusGlyph = m.plusGlyph;
    const placeholder = m.placeholder;
    const mic = m.mic;
    const micGlyph = m.micGlyph;
    for (const [name, value] of [
      ["+ button", plus],
      ["+ glyph", plusGlyph],
      ["placeholder text", placeholder],
      ["mic", mic],
      ["mic glyph", micGlyph],
    ] as const)
      if (!value) out.push(`${name} is not drawn`);
    if (plus && plusGlyph && off(plusGlyph.cy, plus.cy))
      out.push(`+ glyph center y ${f(plusGlyph.cy)} is not the + button's ${f(plus.cy)}`);
    if (micGlyph && mic && off(micGlyph.cy, mic.cy))
      out.push(`mic glyph center y ${f(micGlyph.cy)} is not the mic button's ${f(mic.cy)}`);
    if (plus && mic && off(plus.cy, mic.cy)) out.push(`+ center y ${f(plus.cy)} and mic center y ${f(mic.cy)} differ`);
    if (plus && placeholder && off(plus.cy, placeholder.cy))
      out.push(`+ center y ${f(plus.cy)} and placeholder line center y ${f(placeholder.cy)} differ`);
    if (plusGlyph && micGlyph && m.box) {
      const leading = plusGlyph.cx - m.box.left;
      const trailing = m.box.right - micGlyph.cx;
      if (off(leading, trailing))
        out.push(`+ glyph sits ${f(leading)} px from the box's left, the mic glyph ${f(trailing)} px from its right`);
    }
    // The quiet row's columns: the mode's shield under the + glyph, the context ring's glyph under the mic's.
    if (m.foot && m.modeGlyph && plusGlyph && m.box && off(m.modeGlyph.cx - m.box.left, plusGlyph.cx - m.box.left))
      out.push(
        `quiet row: mode shield center ${f(m.modeGlyph.cx - m.box.left)} px from the box's left, + glyph ${f(plusGlyph.cx - m.box.left)} px`,
      );
    if (m.foot && m.ringGlyph && micGlyph && m.box && off(m.box.right - m.ringGlyph.cx, m.box.right - micGlyph.cx))
      out.push(
        `quiet row: context ring glyph center ${f(m.box.right - m.ringGlyph.cx)} px from the box's right, mic glyph ${f(m.box.right - micGlyph.cx)} px`,
      );
    if (plus && placeholder && off(placeholder.left - plus.right, TEXT_GAP))
      out.push(`placeholder starts ${f(placeholder.left - plus.right)} px after the + button, not ${TEXT_GAP} px`);
    if (m.foot && m.mode && m.model) {
      const axis = m.mode.cy;
      const pieces: [string, Center | null][] = [
        ["mode button", m.mode],
        ["mode text", m.modeText],
        ["mode shield", m.modeGlyph],
        ["model button", m.model],
        ["model text", m.modelText],
        ["context ring", m.ring],
        ["context ring glyph", m.ringGlyph],
      ];
      for (const [name, piece] of pieces)
        if (piece && off(piece.cy, axis))
          out.push(`quiet row: ${name} center y ${f(piece.cy)} is not the mode button's ${f(axis)}`);
    }
    return out;
  };

  for (const width of [720, 420])
    for (const scheme of ["light", "dark"])
      test(`at ${width} px (${scheme}): + , placeholder and mic share one row center; the columns and the quiet row line up`, async () => {
        const m = await measure(width, scheme);
        console.log(JSON.stringify({ width, scheme, measure: m }));
        expect(problems(m)).toEqual([]);
      });
});
