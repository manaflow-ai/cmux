// The gallery's pill spacing variants (agent-pane.composer-row pills-tight, pills-even, pills-roomy;
// Leo 2026-10-22, ask-d4eed794c9) hover the model button in the quiet row under the box, which sets
// its own --acpmux-pill-pad (8 px, composerLocation.css .acpmux-composer-foot). A token set only on
// the page's root never reached that button, so all three showed 8 px sides. This loads the real
// stylesheets and each variant's sheet (composerRow.gallery.ts pillSpacingCss) in Chromium and
// reads the hovered button's sides and height, in the quiet row and in the bar.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { PILL_SPACINGS, pillSpacingCss } from "../src/agent-session/acpmux/composerRow.gallery";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-pill-spacing-gallery.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-pill-spacing-gallery: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer pill spacing gallery", () => test("chromium", () => {}));
    return;
  }
  const dir = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
  const css = ["styles.css", "composerLocation.css", "composerControls.css", "composerStates.css"]
    .map((file) => readFileSync(path.join(dir, file), "utf8"))
    .join("\n");
  const model = `<div class="acpmux-chips"><div class="acpmux-model"><button class="acpmux-picker-button acpmux-pill">Opus 5.5</button></div></div>`;
  const ROWS = {
    "quiet row": `<div class="acpmux-composer-bar acpmux-composer-foot" data-footer-look="plain">${model}</div>`,
    bar: `<div class="acpmux-composer-bar">${model}</div>`,
  };

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const [row, markup] of Object.entries(ROWS)) {
    for (const [name, tokens] of Object.entries(PILL_SPACINGS)) {
      test(`${row}: pills-${name} draws the model's pill ${tokens.pad} from its text, ${tokens.height} tall`, async () => {
        const page = await browser!.newPage();
        try {
          await page.setContent(
            `<style>${css}</style><style>${pillSpacingCss(name as keyof typeof PILL_SPACINGS)}</style>${markup}`,
          );
          const button = page.locator(".acpmux-model .acpmux-picker-button");
          await button.hover();
          const drawn = await button.evaluate((el) => {
            const style = getComputedStyle(el);
            return { start: style.paddingInlineStart, end: style.paddingInlineEnd, height: style.height };
          });
          expect(drawn).toEqual({ start: tokens.pad, end: tokens.pad, height: tokens.height });
        } finally {
          await page.close();
        }
      });
    }
  }
});
