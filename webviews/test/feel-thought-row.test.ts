// Feel check: a thought row opened and closed by a simulated hand (ThoughtRow.tsx, fold.ts).
// Leo, 2026-11-22: "had the whole line be the line? then you expand and it simply shows you the
// rest", "the highlight of the thought thing needs to be highlighted when you're on the line and not
// necessarily on the thought word, because we can collapse from anywhere on the line", "a morphing
// animation to and from thought", and on the simulated-cursor check: "i mean this to say we can use
// it on various other parts of the app".
//
// The probe reads every painted frame; the verdicts are numbers (test/feel/verdicts.ts):
// - a click at the far end of the row, away from its words, opens it once and closes it once, with a
//   steady hand and a shaky one;
// - through the whole morph the row's line keeps its words and its place, frame by frame;
// - the rest unfolds under the line as one move, one way, with no frame that pops, and folds back
//   the same way;
// - the row is one hover target from its brain to its far end;
// - a thought its line holds whole does not open and does not move.
// The report and a recording per scenario go to $CMUX_FEEL_OUT/thought-row (test/feel/report.ts).
import { describe, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { click, play, type Point } from "./feel/cursor";
import { frames, record } from "./feel/probe";
import { chromiumLaunches, expectPass, feelStage } from "./feel/stage";
import type { FeelTrace, ProbeSpec } from "./feel/trace";
import { churn, continuity, flips, values, type Verdicts } from "./feel/verdicts";

await requireBrowserLane("feel-thought-row.test.ts", async () => {
  setDefaultTimeout(180_000);
  if (!(await chromiumLaunches())) {
    describe.skip("feel: thought row", () => test("chromium", () => {}));
    return;
  }

  // A thought that opens is a button; one its line holds whole is a plain row with the same class.
  const ROW = ".cv-thought";
  const LINE = `${ROW} .cv-thought__preview`;
  const SPEC: ProbeSpec = {
    // `rest` is the fold's wrapper, the box the morph sizes; it is in the page only while open.
    boxes: { row: ROW, line: LINE, rest: `${ROW} + .cv-fold` },
    texts: { line: LINE },
    states: { open: { selector: ROW, attr: "aria-expanded" }, hovered: { selector: `${ROW}:hover` } },
  };

  /** No finite animation is running (a fold, a hover tint), then two more painted frames. */
  const settle = async (page: Page) => {
    await frames(page, 2);
    await page.waitForFunction(() =>
      document.getAnimations().every((a) => a.playState !== "running" || a.effect?.getTiming().iterations === Infinity),
    );
    await frames(page, 2);
  };

  const { scenario, testFor } = feelStage({
    entry: "agent-pane.thought-shapes",
    variant: "long",
    component: "thought-row",
    viewport: { width: 900, height: 900 },
    // The thought sits inside the turn's worked group: open the group so its row is on the page.
    prepare: async (page) => {
      await page.locator(`${ROW}, button.cv-worked.is-toggle`).first().waitFor({ state: "visible" });
      const group = page.locator("button.cv-worked.is-toggle").last();
      if ((await group.count()) && (await group.getAttribute("aria-expanded")) !== "true") await group.click();
      await page.locator(ROW).first().waitFor({ state: "visible" });
      await settle(page);
    },
  });

  /** The row's box and two points on its middle line: its far end (past the words) and its start. */
  const aim = async (page: Page) => {
    const box = (await page.locator(ROW).first().boundingBox())!;
    const y = box.y + box.height / 2;
    return { box, far: { x: box.x + box.width - 30, y }, near: { x: box.x + 6, y } };
  };

  /** How far a box's top-left corner strayed from its first frame (px). */
  const strayed = (trace: FeelTrace, name: string) => {
    const first = trace.frames.find((frame) => frame.boxes[name])?.boxes[name];
    if (!first) return Infinity;
    let most = 0;
    for (const frame of trace.frames) {
      const box = frame.boxes[name];
      if (!box) return Infinity;
      most = Math.max(most, Math.abs(box.x - first.x), Math.abs(box.y - first.y));
    }
    return most;
  };

  /** The morph's verdicts, the same for opening and closing. */
  const judgeMorph = (trace: FeelTrace, v: Verdicts, ends: string) => {
    const line = churn(trace, "line");
    const unfold = continuity(trace, "rest", "bottom");
    v.equals("open state, once per change", values(trace, "open").at(-1), ends);
    v.atMost("times the row toggled", flips(trace, "open"), 1);
    v.atMost("times the line's words changed", line.swaps, 0);
    v.atMost("line strayed from its place", strayed(trace, "line"), 0.5, " px");
    v.atMost("row's top-left strayed", strayed(trace, "row"), 0.5, " px");
    v.atLeast("the rest's travel", unfold.travel, 10, " px");
    v.equals("separate moves of the rest", unfold.moves, 1);
    v.atMost("times the rest turned back", unfold.reversals, 0);
    // A pop is 1 (the whole travel in one frame). The fold opens on the settle curve, which spends
    // most of its travel early, and the frame that mounts the rest runs long on a loaded CI runner:
    // 0.7 measured there on two runs of three, so the limit sits between that and a pop.
    v.atMost("largest single-frame step, share of the travel", unfold.maxStepShare, 0.85);
    return { line: { swaps: line.swaps }, lineStrayed: strayed(trace, "line"), unfold };
  };

  describe("feel: thought row", () => {
    for (const [name, wobble] of [
      ["steady", 0],
      ["shaky", 3],
    ] as const)
      testFor(`open-${name}`)(
        `a ${name} click at the row's far end opens it: the line holds, the rest unfolds once`,
        async () => {
          expectPass(
            await scenario(`open-${name}`, async (page, v) => {
              const { far } = await aim(page);
              const trace = await record(page, SPEC, () => click(page, far, { wobble }), { settleFrames: 60 });
              return judgeMorph(trace, v, "true");
            }),
          );
        },
      );

    testFor("close")("a click at the row's far end closes it: the line holds, the rest folds once", async () => {
      expectPass(
        await scenario("close", async (page, v) => {
          const { far } = await aim(page);
          await click(page, far);
          await settle(page);
          const trace = await record(page, SPEC, () => click(page, far), { settleFrames: 60 });
          return judgeMorph(trace, v, "false");
        }),
      );
    });

    testFor("hover-along")("the row is one hover target from its start to its far end", async () => {
      expectPass(
        await scenario("hover-along", async (page, v) => {
          const { box, near, far } = await aim(page);
          const above: Point = { x: near.x, y: box.y - 60 };
          await page.mouse.move(above.x, above.y);
          await frames(page, 2);
          const steps = Array.from({ length: 40 }, (_, i) => ({
            x: near.x + ((far.x - near.x) * i) / 39,
            y: near.y,
            wait: 1,
          }));
          const trace = await record(page, SPEC, () => play(page, steps), { settleFrames: 10 });
          v.equals("hover, once per change", values(trace, "hovered"), [null, "1"]);
          v.atMost("times the row toggled", flips(trace, "open"), 0);
          v.atMost("row's top-left strayed", strayed(trace, "row"), 0.5, " px");
          return { hovered: values(trace, "hovered") };
        }),
      );
    });

    testFor("one-line")("a thought its line holds whole does not open and does not move", async () => {
      expectPass(
        await scenario(
          "one-line",
          async (page, v) => {
            const { far } = await aim(page);
            const trace = await record(page, SPEC, () => click(page, far), { settleFrames: 30 });
            const line = churn(trace, "line");
            v.atMost("times the row toggled", flips(trace, "open"), 0);
            v.atMost("times the line's words changed", line.swaps, 0);
            v.atMost("row's top-left strayed", strayed(trace, "row"), 0.5, " px");
            v.atMost("line strayed from its place", strayed(trace, "line"), 0.5, " px");
            return { open: values(trace, "open") };
          },
          "one-line",
        ),
      );
    });
  });
});
