// cmux-web-test-timeout: 300
// l10n-allow-file: assertions on the English catalog's words.
// A disconnect and reconnect never swaps a chat's screen for the builder new-chat screen ("What should
// we build?", its project picker and the lists under it). Leo, 2026-11-22 14:14Z: "why teh fuck would a
// disconnection make it show up... and we wanted the plain one didnt we? without the chatter intro".
// The stand-in daemon holds its answers to the reconnect's watch and attach (support/papercutChat.ts
// `stall`) past the pane's reconnecting chip, then answers. Every painted frame from before the drop to
// after the reconnect is read, for an empty chat and for a chat with turns:
// - no frame draws the builder question, the hero's picker or the home lists;
// - the empty chat shows the plain new chat (EmptyState.tsx) before, during and after;
// - the chat with turns keeps its rows and never draws an empty state.
// Real Chromium against the pane's dev entry; CI fails the file when it cannot launch it
// (requireBrowserLane). Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-reconnect-no-builder-screen.test.ts
import { afterEach, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

type Frame = { t: number; builder: boolean; plain: boolean; rows: number; recovering: boolean; line: string };

await requireBrowserLane("agent-pane-reconnect-no-builder-screen.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  afterEach(async () => {
    pane?.stall([]);
    await pane?.close();
    await browser?.close();
    pane = undefined;
    browser = undefined;
  });

  /// Every painted frame for `ms`: whether the builder screen, the plain new chat or rows drew.
  const sample = (page: import("playwright").Page, ms: number) =>
    page.evaluate(async (until) => {
      const start = performance.now();
      const seen: Frame[] = [];
      await new Promise<void>((resolve) => {
        window.cmuxAfterPaint(() => {
          const text = document.querySelector(".acpmux-main")?.textContent ?? "";
          seen.push({
            t: Math.round(performance.now() - start),
            builder:
              text.includes("What should we build") ||
              Boolean(document.querySelector(".acpmux-empty-title, .acpmux-empty-choose, .acpmux-home-area")),
            plain: Boolean(document.querySelector("[data-plain-new-chat]")),
            rows: document.querySelectorAll("[data-row-id]").length,
            // The drop's sign: the connection chip (HostError.tsx ConnectionChip, #49415) or a host line.
            recovering: Boolean(document.querySelector("[data-host-recovering]")),
            line: document.querySelector(".acpmux-host-chip-words, .acpmux-host-line-message")?.textContent ?? "",
          });
          if (performance.now() - start < until) return true;
          resolve();
          return false;
        });
      });
      return seen;
    }, ms);

  for (const turns of [0, 3])
    test(`${turns ? "a chat with turns" : "an empty chat"}: a disconnect and reconnect never draws the builder screen`, async () => {
      browser = await chromium.launch({ headless: true });
      pane = await papercutPane(() => browser!, {
        turns,
        running: false,
        ...(turns ? {} : { ready: ".acpmux-composer" }),
      });
      const page = await pane.open({ width: 900, height: 700 });
      try {
        const before = await sample(page, 300);
        // The drop, held past the pane's reconnecting chip (10 s), then the daemon answers.
        pane.stall(["_acpmux/watch", "_acpmux/attach"]);
        pane.drop();
        const during = await sample(page, 11_500);
        const reconnecting = during.some((frame) => frame.recovering || frame.line.startsWith("Reconnecting"));
        pane.stall([]);
        const after = await sample(page, 3_000);
        const all = [...before, ...during, ...after];
        console.log(
          `RECONNECT-NO-BUILDER ${JSON.stringify({
            turns,
            frames: all.length,
            builderFrames: all.filter((frame) => frame.builder).length,
            plainFrames: all.filter((frame) => frame.plain).length,
            reconnecting,
          })}`,
        );
        expect(reconnecting).toBe(true);
        expect(all.filter((frame) => frame.builder).map((frame) => frame.t)).toEqual([]);
        if (turns) {
          expect(all.filter((frame) => frame.plain).map((frame) => frame.t)).toEqual([]);
          expect(after.at(-1)!.rows).toBeGreaterThan(0);
        } else {
          expect(before.every((frame) => frame.plain)).toBe(true);
          expect(after.at(-1)!.plain).toBe(true);
        }
      } finally {
        pane.stall([]);
        await page.close();
      }
    });
});
