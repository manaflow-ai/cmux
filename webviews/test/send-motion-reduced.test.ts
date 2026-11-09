// l10n-allow-file: test fixture markup, not shipped UI.
// The app's own Reduce Motion (Calm mode included) reaches the pane as a theme whose move step is 0
// while its fades stay on, and WebKit can still answer `prefers-reduced-motion: no-preference`. A
// sent prompt then keeps a plain fade on the fade setting, and nothing moves: the bubble's edge and
// the thread's rise run the move-scaled send step (0), its fades `--agent-motion-send-fade`
// (shared/theme.ts, conversation.css SEND-ENTRANCE). Review of #38159, F1.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path_ from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("send-motion-reduced.test.ts", async () => {
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-motion-reduced: skipping (run `bunx playwright install chromium`)");
    describe.skip("send entrance under Reduce Motion", () => test("chromium", () => {}));
    return;
  }
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  // Every entrance a send starts, under both Reduce Motion paths: the system's (the media query) and
  // the app's (move step 0, fades on, the media query still at no-preference). Each fades, on a
  // nonzero clock, with opacity-only keyframes; the bubble's edge never moves.
  const FADES = new Set(["cv-enter-fade", "cv-message-enter"]);
  for (const path of [
    { name: "system", media: "reduce" as const, tokens: "--agent-motion-send: 180ms; --agent-motion-send-fade: 180ms" },
    {
      name: "app",
      media: "no-preference" as const,
      tokens: "--agent-motion-send: 0ms; --agent-motion-send-fade: 120ms",
    },
  ])
    test(`${path.name} Reduce Motion: a sent prompt, its reply, its picture and its thinking row fade; nothing moves`, async () => {
      const css = readFileSync(
        path_.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
        "utf8",
      );
      const page = await browser!.newPage();
      try {
        await page.emulateMedia({ reducedMotion: path.media });
        await page.setContent(`<!doctype html><html style="${path.tokens}; --agent-motion-in: 120ms">
        <body><div class="acpmux-thread">
          <article class="acpmux-row acpmux-user acpmux-row--message-enter"><div class="acpmux-row__message-presentation">
            <div class="cv-user"><img class="cv-user__image cv-enter" alt=""><div class="cv-user__bubble"><p>sent</p></div></div>
          </div></article>
          <article class="acpmux-row acpmux-thinking acpmux-row--enter">Thinking</article>
          <article class="acpmux-row acpmux-assistant acpmux-row--message-enter"><div class="acpmux-row__message-presentation">reply</div></article>
        </div></body></html>`);
        await page.addStyleTag({ content: css });
        const clocks = await page.evaluate(() => {
          const read = (selector: string) => {
            const style = getComputedStyle(document.querySelector(selector)!);
            return { name: style.animationName, duration: Number.parseFloat(style.animationDuration) };
          };
          return {
            prompt: read(".acpmux-user .acpmux-row__message-presentation"),
            reply: read(".acpmux-assistant .acpmux-row__message-presentation"),
            thinking: read(".acpmux-thinking"),
            picture: read(".cv-user__image"),
            bubble: read(".cv-user__bubble"),
            text: read(".cv-user__bubble > p"),
          };
        });
        for (const part of ["prompt", "reply", "thinking", "picture"] as const) {
          expect(FADES.has(clocks[part].name), `${path.name}: the ${part} fades (${clocks[part].name})`).toBe(true);
          expect(clocks[part].duration, `${path.name}: the ${part}'s fade has a clock`).toBeGreaterThan(0);
        }
        expect(
          clocks.bubble.name === "none" || clocks.bubble.duration === 0,
          `${path.name}: the bubble's edge does not move (${JSON.stringify(clocks.bubble)})`,
        ).toBe(true);
        expect(clocks.text.name === "none" || FADES.has(clocks.text.name), `${path.name}: its text only fades`).toBe(
          true,
        );
      } finally {
        await page.close();
      }
    });
});
