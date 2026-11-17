// l10n-allow-file: test fixture prompts, not shipped UI.
// cmux-web-test-timeout: 300
//
// A new chat settles with no layout shift after it starts. Leo, 2026-11-17, of his new cmux NEXT
// chat (Codex, GPT-6.1 Sol, Full access): "we need to test out more of these permission related
// combinations in ci and whatnot so things are as people would expect + that chats settle with no
// unnecessary layout shifts after they start and all this picking models and effort levels and
// options are smooth and they don't randomly change to other things and that things are working as
// expected".
//
// The real pane against the real acpmux daemon and its stand-in harnesses (support/realAcpmux.ts):
// open a New Tab, send the first message, and read where the composer, the header, the picker row
// and its chips, the first message and the transcript sit on every painted frame through the
// harness starting, the reply streaming in and the turn ending. Once the chat's view is up (the
// frame the first message shows), none of them moves: no composer jump, no header or picker row
// reflow, no placeholder swapped for a view of another height, no empty-chat view coming back. The
// one thing that may change is the transcript growing downward as the reply arrives. The browser's
// own layout-shift entries over the same window add up to the CLS-style score, which must be 0.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Page } from "playwright";
import { COMPOSER_EDITOR, MODEL_PICKER } from "../src/agent-session/acpmux/composerSelectors";
import { COMPACT_MODEL_MENU, MODEL_ROW_NAME } from "./support/compactModelMenu";
import { installPaintedFrames } from "./support/paintedFrames";
import { paneUrl } from "./support/realAcpmux";
import { openRealPaneLane, realPaneLane, turnDone, type RealPaneLane } from "./support/realPaneLane";
import { requireBrowserLane } from "./support/requireBrowserLane";
import {
  collect,
  installShiftRecorder,
  mark,
  scoreAfter,
  shiftsAfter,
  startFrameSampler,
  type SettleFrame,
} from "./support/settleFrames";

await requireBrowserLane("agent-pane-new-chat-settles.test.ts", async () => {
  await realPaneLane("agent-pane-new-chat-settles.test.ts", async () => {
    setDefaultTimeout(240_000);
    let lane: RealPaneLane;
    beforeAll(async () => {
      lane = await openRealPaneLane();
    });
    afterAll(async () => {
      await lane?.close();
    });
    const out = process.env.FAST_CHECKS_OUT;

    /** The first painted frame the chat's view shows its first message in. */
    const chatFrom = (frames: SettleFrame[]) => frames.find((frame) => frame.parts.firstMessage)?.t;

    async function newChat(page: Page, harness: "codex" | "claude") {
      await installPaintedFrames(page);
      await installShiftRecorder(page);
      await page.goto(paneUrl(lane.base, lane.daemon, "newtab"));
      await page.locator(".nt-field").waitFor();
      // The New Tab's own pickers have their values before the person types.
      await page.waitForFunction(() => !!document.querySelector(".acpmux-model-name")?.textContent?.trim());
      await page.waitForFunction(() => !!document.querySelector(".acpmux-access-trigger"));
      // acpmux starts new chats on Codex; Claude Code is one pick away, on its tab of the model menu.
      if (harness === "claude") {
        await page.locator(MODEL_PICKER).first().click();
        const menu = page.locator(COMPACT_MODEL_MENU).first();
        await menu.waitFor();
        await menu.locator('.acpmux-cols-tab[aria-label^="Claude"]').first().click();
        await menu.locator("[role=option]").first().locator(MODEL_ROW_NAME).first().click();
        await page.keyboard.press("Escape");
        await page.waitForFunction(() => document.querySelector(".acpmux-cols") === null);
      }
    }

    for (const harness of ["codex", "claude"] as const) {
      test(`a new ${harness} chat holds still from its first message through its first reply`, async () => {
        const context = await lane.browser.newContext({ viewport: { width: 1000, height: 760 } });
        const page = await context.newPage();
        await newChat(page, harness);
        await startFrameSampler(page);
        await mark(page, "start");
        await page.locator(".nt-field").click();
        await page.keyboard.type("Add retry to the uploader");
        await mark(page, "send");
        await page.keyboard.press("Enter");
        await page.locator(".acpmux-user").first().waitFor({ timeout: 30_000 });
        await mark(page, "shown");
        // The harness is ready once acpmux answered the chat's session/new: the pane has its session.
        await page.waitForFunction(() => !!(window as any).cmuxAcpmuxDebug?.chatState?.().sessionId);
        await mark(page, "ready");
        await page.locator(COMPOSER_EDITOR).first().waitFor();
        // The reply: the stand-in streams "ok" (codex) or its arguments (claude), then ends the turn.
        await page.waitForFunction(() => !!(window as any).cmuxAcpmuxDebug?.chatState?.().lastAssistant, undefined, {
          timeout: 60_000,
        });
        await mark(page, "streaming");
        await turnDone(page);
        await mark(page, "done");
        // Two seconds after the turn ends: anything that lands late (titles, usage, the context ring).
        for (let i = 0; i < 120; i++) await page.evaluate(() => window.cmuxPaintFrame());
        const { frames, shifts, marks } = await collect(page);
        const from = chatFrom(frames);
        expect(from).toBeDefined();
        const moves = shiftsAfter(frames, from!, ["transcript"]);
        const score = scoreAfter(shifts, marks.send!);
        const scoreAfterShown = scoreAfter(shifts, from!);
        // The score in each phase: send to the chat showing, then to the harness ready, the reply
        // streaming, the turn done, and the two seconds after.
        const edges = [marks.send!, from!, marks.ready!, marks.streaming!, marks.done!, Infinity];
        const names = ["send", "shown", "ready", "streaming", "done"];
        const phases = Object.fromEntries(
          names.map((name, at) => [
            name,
            {
              cls: Number(scoreAfter(shifts, edges[at]!, edges[at + 1]!).toFixed(4)),
              moves: moves.filter((m) => m.t >= edges[at]! && m.t < edges[at + 1]!).length,
            },
          ]),
        );
        console.log(`settle ${harness} phases: ${JSON.stringify(phases)}`);
        const report = {
          phases,
          harness,
          frames: frames.length,
          marks,
          chatFrom: from,
          moves: moves.slice(0, 40),
          score,
          scoreAfterShown,
          shifts: shifts.filter((s) => s.t >= marks.send!),
        };
        if (out) {
          mkdirSync(out, { recursive: true });
          writeFileSync(path.join(out, `settle-${harness}.json`), JSON.stringify(report, null, 1));
          await page.screenshot({ path: path.join(out, `settle-${harness}.png`) });
        }
        console.log(
          `settle ${harness}: ${moves.length} moves after the chat showed, CLS-style ${scoreAfterShown.toFixed(4)} after it (${score.toFixed(4)} from the send)`,
        );
        for (const move of moves.slice(0, 12))
          console.log(
            `  ${move.part} moved ${move.px.toFixed(1)}px at ${Math.round(move.t - from!)}ms: ${JSON.stringify(move.from)} -> ${JSON.stringify(move.to)}`,
          );
        // No empty-chat view and no New Tab field once the chat shows.
        expect(frames.filter((f) => f.t >= from! && (f.parts.empty || f.parts.newTab)).length).toBe(0);
        expect(moves).toEqual([]);
        expect(scoreAfterShown).toBe(0);
        await context.close();
      });
    }
  });
});
