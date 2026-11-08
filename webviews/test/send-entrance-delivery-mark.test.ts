// l10n-allow-file: test fixture markup, not shipped UI.
// A sent prompt's bubble opens leftward on the send motion with a clip (conversation.css
// SEND-ENTRANCE). The clip is the entrance's only: once it ends the bubble draws unclipped, so the
// "Sending" clock and "Still sending" label, which sit just outside the bubble's left edge
// (PromptDelivery.tsx, `.cv-user__delivery`), show for a send still pending after a second.
// Review of #38159, F1.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("send-entrance-delivery-mark.test.ts", async () => {
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-entrance-delivery-mark: skipping (run `bunx playwright install chromium`)");
    describe.skip("delivery mark after the send entrance", () => test("chromium", () => {}));
    return;
  }
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  test("a send still pending past its entrance shows its Still sending mark beside the bubble", async () => {
    const css = readFileSync(
      path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
      "utf8",
    );
    const page = await browser!.newPage({ viewport: { width: 800, height: 300 } });
    try {
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.setContent(`<!doctype html><html style="--agent-motion-send: 265ms; --agent-motion-send-fade: 265ms; --agent-motion-in: 120ms; --grid-cards-radius: 12px">
        <body style="margin:0"><div class="acpmux-thread" style="padding: 40px 40px 40px 400px">
          <article class="acpmux-row acpmux-user acpmux-row--message-enter"><div class="acpmux-row__message-presentation">
            <div class="cv-user"><div class="cv-user__body"><div class="cv-user__bubble" style="position: relative; width: 300px">
              <p>still on its way</p>
              <output class="cv-user__status cv-user__delivery" data-delivery="sending"><span id="mark">Still sending</span></output>
            </div></div></div>
          </div></article>
        </div></body></html>`);
      await page.addStyleTag({ content: css });
      // Past the entrance (every animation it started has ended), the send still pending.
      await page.waitForFunction(
        () =>
          document.getAnimations().length > 0 &&
          document.getAnimations().every((animation) => animation.playState === "finished"),
      );
      const shown = await page.evaluate(() => {
        const mark = document.getElementById("mark")!;
        const box = mark.getBoundingClientRect();
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
        return {
          clip: getComputedStyle(document.querySelector(".cv-user__bubble")!).clipPath,
          width: box.width,
          hit: !!hit && mark.contains(hit),
        };
      });
      expect(shown.width, "the mark is laid out").toBeGreaterThan(0);
      expect(shown.clip, "the bubble keeps no clip after its entrance").toBe("none");
      expect(shown.hit, "the mark is drawn, not clipped away").toBe(true);
    } finally {
      await page.close();
    }
  });
});
