// Feel check: placing a Chief's picture in its circle (pages/home-channels/PictureCrop.tsx,
// picture.ts), on its gallery entry pages.home-channels.picture-crop. Leo, 2026-11-22: "these should
// be doable via automation. the "feel" and "vibes" thing. you can simulate cursors clicking around",
// and on the simulated-cursor check: "i mean this to say we can use it on various other parts of the
// app".
//
// A simulated cursor (test/feel/cursor.ts) drags the picture slow, fast, shaky and in bursts, past its
// edge and back, clicks it without dragging, presses just outside the circle and drags, double-clicks
// it, and drags it five times in a row, on a wide, a tall and a zoomed-in still. The probe reads every
// painted frame. Verdicts (numbers, not screenshots; test/feel/verdicts.ts):
// - the point of the picture the hand grabbed stays under it, 1:1, with no jump, and stays put when it
//   lets go; at the picture's edge it waits, and picks up again only when the hand is back over it;
// - a click, a double-click or a press just outside the circle moves nothing.
// The report and a recording per scenario go to $CMUX_FEEL_OUT/picture-crop (test/feel/report.ts).
import { describe, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { aroundHandle, click, doubleClick, drag, dragPath, type DragStyle, type Point } from "./feel/cursor";
import { frames, record } from "./feel/probe";
import { chromiumLaunches, expectPass, feelStage } from "./feel/stage";
import type { ProbeSpec } from "./feel/trace";
import { follow, still } from "./feel/verdicts";

await requireBrowserLane("feel-picture-crop.test.ts", async () => {
  setDefaultTimeout(120_000);
  if (!(await chromiumLaunches())) {
    describe.skip("feel: picture crop", () => test("chromium", () => {}));
    return;
  }

  const VIEW = ".lg-picture-crop-view";
  const SPEC: ProbeSpec = {
    boxes: { picture: `${VIEW} img`, view: VIEW, slider: '.lg-picture-crop input[type="range"]' },
  };

  const { scenario, testFor } = feelStage({
    entry: "pages.home-channels.picture-crop",
    variant: "landscape",
    component: "picture-crop",
    viewport: { width: 400, height: 300 },
    prepare: async (page) => void (await page.waitForSelector(`${VIEW} img`)),
    known: {
      // Red today, no lane on it yet. PictureCrop.tsx moves the crop by each pointermove's delta, so
      // the hand's way past the edge is forgotten: coming back moves the picture at once, and the
      // point it grabbed ends 20 px from the hand.
      overshoot: "unowned: back from past the edge, the picture moves at once and leaves the hand",
    },
  });

  const viewBox = async (page: Page) => {
    const box = (await page.locator(VIEW).boundingBox())!;
    return { x: box.x, y: box.y, w: box.width, h: box.height };
  };
  const centre = async (page: Page): Promise<Point> => aroundHandle(await viewBox(page)).centre;

  /** A drag of the picture by `dx`, `dy` in `style`, judged on the edges it can move along. */
  const dragScenario = (variant: string, style: DragStyle, dx: number, dy: number) => {
    const name = `${variant}-drag-${style}`;
    testFor(name)(
      `${variant}: drag ${style} by ${dx},${dy}: the grabbed point stays under the hand, no jump`,
      async () => {
        const verdicts = await scenario(
          name,
          async (page, v) => {
            const from = await centre(page);
            const trace = await record(page, SPEC, () =>
              drag(page, from, dragPath(from, { x: from.x + dx, y: from.y + dy }, style)),
            );
            const numbers: Record<string, unknown> = {};
            for (const [axis, edge, d] of [
              ["x", "left", dx],
              ["y", "top", dy],
            ] as const) {
              if (d === 0) continue;
              const report = follow(trace, { box: "picture", edge });
              v.atMost(`${axis}: picture off the grab point (max)`, report.maxError, 1, " px");
              v.atMost(`${axis}: jumps (frames off the hand by over 4 px)`, report.jumps.length, 0);
              v.atMost(`${axis}: move after release`, report.releaseMove, 0.5, " px");
              v.atLeast(`${axis}: picture travel / hand travel`, report.coverage, 0.9);
              numbers[axis] = report;
            }
            return numbers;
          },
          variant,
        );
        expectPass(verdicts);
      },
    );
  };

  describe("feel: picture crop drag", () => {
    // The wide still at zoom 1 has 48 px of room each way across the circle, none up and down.
    for (const style of ["slow", "fast", "jitter", "burst"] as const) dragScenario("landscape", style, -40, 0);
    dragScenario("portrait", "slow", 0, 40);
    dragScenario("portrait", "burst", 0, 40);
    dragScenario("zoomed", "slow", 50, -30);
    dragScenario("zoomed", "jitter", 50, -30);

    testFor("overshoot")(
      "past the picture's edge and back: it waits at its edge and picks up only under the hand",
      async () => {
        const verdicts = await scenario("overshoot", async (page, v) => {
          const from = await centre(page);
          // 60 px right: 12 px past the 48 the picture has, out to 80 and back to 60.
          const trace = await record(page, SPEC, () =>
            drag(page, from, dragPath(from, { x: from.x + 60, y: from.y }, "overshoot")),
          );
          const report = follow(trace, { box: "picture", edge: "left" });
          v.atMost("picture off the grab point (max)", report.maxError, 1, " px");
          v.atMost("jumps", report.jumps.length, 0);
          v.atMost("move after release", report.releaseMove, 0.5, " px");
          return { ...report };
        });
        expectPass(verdicts);
      },
    );

    for (const [name, wobble] of [
      ["click", 0],
      ["wobble-3px", 3],
    ] as const)
      testFor(name)(`a ${name} on the picture (no drag) moves it no further than the hand did`, async () => {
        const verdicts = await scenario(name, async (page, v) => {
          const at = await centre(page);
          const trace = await record(page, SPEC, () => click(page, at, { wobble }));
          const report = still(trace);
          // The picture is held 1:1, so a shaking hand may move it by its shake, never more.
          v.atMost("picture moved", report.moved.picture ?? 0, wobble + 0.5, " px");
          v.atMost("circle moved", report.moved.view ?? 0, 0.5, " px");
          v.atMost("layout shift", report.shift, 0.01);
          return report;
        });
        expectPass(verdicts);
      });

    testFor("miss-around")("a press just outside the circle, then a drag, moves nothing", async () => {
      const verdicts = await scenario("miss-around", async (page, v) => {
        const box = await viewBox(page);
        const around = aroundHandle(box, 3);
        // Above and below the circle, and its box's corner: outside the round edge, inside its box.
        const misses: Record<string, Point> = {
          above: around.above,
          below: around.below,
          corner: { x: box.x + 6, y: box.y + 6 },
        };
        let worst = 0;
        const moved: Record<string, number> = {};
        for (const [side, at] of Object.entries(misses)) {
          const trace = await record(page, SPEC, () => drag(page, at, dragPath(at, { x: at.x - 30, y: at.y }, "slow")));
          moved[side] = still(trace).moved.picture ?? 0;
          worst = Math.max(worst, moved[side]!);
          v.atMost(`${side}: picture moved`, moved[side]!, 0.5, " px");
        }
        return { moved, worst };
      });
      expectPass(verdicts);
    });

    testFor("double-click")("a double-click on the picture moves nothing and selects nothing", async () => {
      const verdicts = await scenario("double-click", async (page, v) => {
        const at = await centre(page);
        const trace = await record(page, SPEC, () => doubleClick(page, at));
        const report = still(trace);
        const selected = await page.evaluate(() => getSelection()?.toString() ?? "");
        v.atMost("picture moved", report.moved.picture ?? 0, 0.5, " px");
        v.equals("text selected", selected, "");
        return { ...report, selected };
      });
      expectPass(verdicts);
    });

    testFor("repeat")("five drags in a row, back and forth: each follows the hand, none jumps", async () => {
      const verdicts = await scenario("repeat", async (page, v) => {
        let worst = 0;
        let jumps = 0;
        for (const dx of [-30, 30, -20, 40, -10]) {
          const at = await centre(page);
          const trace = await record(
            page,
            SPEC,
            () => drag(page, at, dragPath(at, { x: at.x + dx, y: at.y }, "slow")),
            { settleFrames: 6 },
          );
          const report = follow(trace, { box: "picture", edge: "left" });
          worst = Math.max(worst, report.maxError);
          jumps += report.jumps.length;
          await frames(page, 2);
        }
        v.atMost("picture off the grab point (worst of five)", worst, 1, " px");
        v.atMost("jumps (all five)", jumps, 0);
        return { worst, jumps };
      });
      expectPass(verdicts);
    });
  });
});
