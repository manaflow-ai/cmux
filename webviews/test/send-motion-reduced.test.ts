// l10n-allow-file: test fixture markup, not shipped UI.
// The app's own Reduce Motion (Calm mode included) reaches the pane as a theme whose move step is 0
// while its fades stay on, and WebKit can still answer `prefers-reduced-motion: no-preference`. A
// sent prompt, its picture and its thinking row are then in place at once, as everywhere (Leo,
// 2026-11-11: "that slow settle animation is just so bad. Like, just do it."): the send clock and its
// fade are 0 (shared/theme.ts, conversation.css SEND-ENTRANCE), and nothing moves. A reply still
// fades in. Review of #38159, F1; review of #41550, F2.
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
  // the app's (the theme's 0 send clock and fade, the media query still at no-preference). The sent
  // prompt, its picture and its thinking row draw whole at once; the reply fades, on a nonzero clock,
  // with opacity-only keyframes; the bubble's edge never moves. A turn that already has work draws
  // "Working for" between the prompt and its thinking row (turns.ts, liveTurnClock `top`): the
  // thinking row is still whole at once. "Working for" comes with the turn's first work, later, and
  // fades as any arrival (turn-transition-jumps: no row pops in at full ink).
  const FADES = new Set(["cv-enter-fade", "cv-message-enter"]);
  for (const path of [
    { name: "system", media: "reduce" as const, tokens: "--agent-motion-send: 0ms; --agent-motion-send-fade: 0ms" },
    { name: "app", media: "no-preference" as const, tokens: "--agent-motion-send: 0ms; --agent-motion-send-fade: 0ms" },
  ])
    for (const working of [false, true])
      test(`${path.name} Reduce Motion${working ? ", under Working for" : ""}: a sent prompt, its picture and its thinking row are in place at once; the reply fades`, async () => {
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
          ${working ? '<article class="acpmux-row acpmux-working acpmux-row--enter">Working for 1s</article>' : ""}
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
          for (const part of ["prompt", "thinking", "picture"] as const)
            expect(
              clocks[part].name === "none" || clocks[part].duration === 0,
              `${path.name}: the ${part} is whole at once (${JSON.stringify(clocks[part])})`,
            ).toBe(true);
          expect(FADES.has(clocks.reply.name), `${path.name}: the reply fades (${clocks.reply.name})`).toBe(true);
          expect(clocks.reply.duration, `${path.name}: the reply's fade has a clock`).toBeGreaterThan(0);
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
