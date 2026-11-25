// Feel check: a turn's action row (Copy, Fork, Pin, Read aloud, ⋯, then its age) revealed by a simulated
// hand (conversation.css .acpmux-turnSummary .cv-turn-actions; VirtualTranscript data-turn-revealed).
// Leo, 2026-11-22: "claude hides buttons until you hover over the relevant area of a turn response. they
// do a SUPER FAST fade in and fade out for it. which i like" and "i think we go with claude code here.
// idk when we decided to always show all buttons always. let's not."
//
// The probe reads every painted frame's computed opacity of each turn's action row and each row's box;
// the verdicts are numbers:
// - the pointer entering a turn shows its row at full within the fast fade (about 120 ms), and leaving
//   hides it within about 80 ms;
// - a fast sweep across every turn moves no row (0 px) and never shows more than the pointed turn's row;
// - the pointer on the row itself keeps it at full;
// - keyboard focus inside the turn shows it.
// The report and a recording per scenario go to $CMUX_FEEL_OUT/turn-actions-hover (test/feel/report.ts).
import { describe, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { frames } from "./feel/probe";
import { chromiumLaunches, expectPass, feelStage } from "./feel/stage";

type Sample = { t: number; ops: number[]; ys: number[]; hs: number[] };

await requireBrowserLane("feel-turn-actions-hover.test.ts", async () => {
  setDefaultTimeout(180_000);
  if (!(await chromiumLaunches())) {
    describe.skip("feel: turn actions hover", () => test("chromium", () => {}));
    return;
  }

  const TURN = ".acpmux-turnSummary";
  const ROW = `${TURN} .cv-turn-actions`;

  const { scenario, testFor } = feelStage({
    entry: "agent-pane.transcript-row-alignment",
    variant: "mix",
    component: "turn-actions-hover",
    viewport: { width: 900, height: 1120 },
    prepare: async (page) => {
      await page.locator(ROW).first().waitFor({ state: "attached" });
      await frames(page, 4);
    },
  });

  /** Samples every painted frame for `ms`: each turn row's computed opacity and its box's top and height. */
  const sample = (page: Page, ms: number) =>
    page.evaluate(
      ({ sel, ms }) =>
        new Promise<{ start: number; samples: Sample[]; firstMove: number | null }>((resolve) => {
          const out: Sample[] = [];
          let firstMove: number | null = null;
          const onMove = (e: Event) => {
            if (firstMove === null) firstMove = e.timeStamp;
          };
          window.addEventListener("pointermove", onMove, { capture: true });
          window.addEventListener("focusin", onMove, { capture: true });
          const start = performance.now();
          const tick = (t: number) => {
            const rows = [...document.querySelectorAll<HTMLElement>(sel)];
            out.push({
              t,
              ops: rows.map((r) => Number(getComputedStyle(r).opacity)),
              ys: rows.map((r) => r.getBoundingClientRect().top),
              hs: rows.map((r) => r.getBoundingClientRect().height),
            });
            if (t - start < ms) requestAnimationFrame(tick);
            else {
              window.removeEventListener("pointermove", onMove, { capture: true });
              window.removeEventListener("focusin", onMove, { capture: true });
              resolve({ start, samples: out, firstMove });
            }
          };
          requestAnimationFrame(tick);
        }),
      { sel: ROW, ms },
    );

  /** Starts sampling, then runs `act` once the sampler is running. */
  const during = async (page: Page, ms: number, act: () => Promise<void>) => {
    const pending = sample(page, ms);
    await frames(page, 1);
    await act();
    return pending;
  };

  const turnBox = async (page: Page, i: number) => (await page.locator(TURN).nth(i).boundingBox())!;

  /** ms from the trigger to the first frame where `pred` holds for row i; frames in between. */
  const timeTo = (r: Awaited<ReturnType<typeof sample>>, i: number, pred: (o: number) => boolean) => {
    const t0 = r.firstMove ?? r.start;
    const after = r.samples.filter((s) => s.t >= t0);
    const hit = after.findIndex((s) => pred(s.ops[i]));
    return hit < 0 ? { ms: Infinity, frames: after.length } : { ms: after[hit].t - t0, frames: hit + 1 };
  };

  const drift = (r: Awaited<ReturnType<typeof sample>>) => {
    let most = 0;
    const first = r.samples[0];
    for (const s of r.samples)
      s.ys.forEach((y, i) => {
        most = Math.max(most, Math.abs(y - first.ys[i]), Math.abs(s.hs[i] - first.hs[i]));
      });
    return most;
  };

  describe("feel: turn actions hover", () => {
    testFor("enter")("the pointer entering a turn shows its row at full on the fast fade", async () => {
      expectPass(
        await scenario("enter", async (page, v) => {
          const box = await turnBox(page, 0);
          const r = await during(page, 600, () => page.mouse.move(box.x + box.width / 2, box.y + box.height / 2));
          const rest = r.samples[0].ops[0];
          const firstInk = timeTo(r, 0, (o) => o > 0.01);
          const full = timeTo(r, 0, (o) => o >= 0.99);
          v.atMost("row opacity at rest", rest, 0.01);
          v.atMost("ms to full opacity", full.ms, 200, " ms");
          v.atLeast("frames of fade (not a pop)", full.frames, 2);
          return { rest, firstInkMs: firstInk.ms, fullMs: full.ms, fadeFrames: full.frames, shiftPx: drift(r) };
        }),
      );
    });

    testFor("leave")("the pointer leaving a turn hides its row on the faster fade", async () => {
      expectPass(
        await scenario("leave", async (page, v) => {
          const box = await turnBox(page, 0);
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await page.waitForTimeout(400);
          const r = await during(page, 600, () => page.mouse.move(2, 2));
          const gone = timeTo(r, 0, (o) => o <= 0.01);
          v.atMost("ms to hidden", gone.ms, 160, " ms");
          v.atMost("row moved", drift(r), 0, " px");
          return { hiddenMs: gone.ms, fadeFrames: gone.frames, shiftPx: drift(r) };
        }),
      );
    });

    testFor("sweep")("a fast sweep across every turn moves no row and shows only the pointed one", async () => {
      expectPass(
        await scenario("sweep", async (page, v) => {
          const n = await page.locator(TURN).count();
          const boxes = await Promise.all(Array.from({ length: n }, (_, i) => turnBox(page, i)));
          const x = boxes[0].x + boxes[0].width / 2;
          const top = Math.max(2, boxes[0].y - 20);
          const bottom = boxes[n - 1].y + boxes[n - 1].height + 20;
          const r = await during(page, 900, async () => {
            for (let k = 0; k <= 30; k++) await page.mouse.move(x, top + ((bottom - top) * k) / 30);
            for (let k = 30; k >= 0; k--) await page.mouse.move(x, top + ((bottom - top) * k) / 30);
            await page.mouse.move(2, 2);
          });
          const shownAtOnce = Math.max(...r.samples.map((s) => s.ops.filter((o) => o >= 0.99).length));
          const settled = r.samples.at(-1)!.ops;
          v.atMost("row moved during the sweep", drift(r), 0, " px");
          v.atMost("rows at full in one frame", shownAtOnce, 1);
          v.atMost("rows still shown after the pointer left", settled.filter((o) => o > 0.01).length, 0);
          return { turns: n, frames: r.samples.length, shiftPx: drift(r), shownAtOnce };
        }),
      );
    });

    testFor("on-row")("the pointer on the row itself keeps it at full", async () => {
      expectPass(
        await scenario("on-row", async (page, v) => {
          const row = (await page.locator(ROW).first().boundingBox())!;
          await page.mouse.move(row.x + 10, row.y + row.height / 2);
          await page.waitForTimeout(300);
          const r = await during(page, 500, () => page.mouse.move(row.x + 40, row.y + row.height / 2));
          const least = Math.min(...r.samples.map((s) => s.ops[0]));
          v.atLeast("least opacity while on the row", least, 0.99);
          return { minOpacity: least };
        }),
      );
    });

    testFor("keyboard")("keyboard focus inside the turn shows its row", async () => {
      expectPass(
        await scenario("keyboard", async (page, v) => {
          const r = await during(page, 500, async () => {
            await page
              .locator(`${ROW} button`)
              .first()
              .focus({ focusVisible: true } as never);
          });
          const full = timeTo(r, 0, (o) => o >= 0.99);
          v.atMost("ms to full on focus", full.ms, 50, " ms");
          return { fullMs: full.ms };
        }),
      );
    });
  });
});
