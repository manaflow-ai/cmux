// Feel check: the composer hat's header while its work changes under it (SubagentTray.tsx,
// trayHeadOrder.ts, trayMotion.tsx). Leo, 2026-11-22: "the swapping gets jarring. it's too adhd-ish",
// and "these should be doable via automation. the "feel" and "vibes" thing. you can simulate cursors
// clicking around."
//
// The stage (agent-pane.composer-hat-head, ComposerHatHeadStage.tsx) is fed bursts: a subagent's steps
// arriving faster than anyone reads, subagents joining one after another, and a command joining.
// The probe reads every painted frame; the verdicts are numbers (test/feel/verdicts.ts):
// - the live line swaps at a pace a reader keeps: each line stays up long enough to read, and the
//   swaps per second stay low however fast the steps come;
// - the header's width holds while its words change (no breathing), and it never moves or shifts the
//   page;
// - subagents joining in a burst change the header's words at that same reading pace, not once each.
// The report and a recording per scenario go to $CMUX_FEEL_OUT/composer-hat (test/feel/report.ts).
import { describe, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { frames, record } from "./feel/probe";
import { chromiumLaunches, expectPass, feelStage } from "./feel/stage";
import type { ProbeSpec } from "./feel/trace";
import { churn, still } from "./feel/verdicts";

await requireBrowserLane("feel-composer-hat.test.ts", async () => {
  setDefaultTimeout(120_000);
  if (!(await chromiumLaunches())) {
    describe.skip("feel: composer hat", () => test("chromium", () => {}));
    return;
  }

  const HEAD = ".acpmux-running-tray__head";
  const SPEC: ProbeSpec = {
    boxes: { head: HEAD, tray: ".acpmux-running-tray", composer: ".acpmux-composer" },
    texts: {
      title: `${HEAD} .acpmux-running-tray__title`,
      latest: `${HEAD} .acpmux-running-tray__latest`,
      more: `${HEAD} .acpmux-running-tray__more`,
    },
  };

  // Red on feat-cmux-next today; the composer-hat-calm lane is calming the header.
  const FIX = "the composer-hat-calm lane: the header swaps its words as fast as they come";
  const { scenario, testFor } = feelStage({
    entry: "agent-pane.composer-hat-head",
    variant: "running",
    component: "composer-hat",
    viewport: { width: 480, height: 240 },
    prepare: async (page) => void (await page.waitForSelector(HEAD)),
    known: Object.fromEntries(
      ["steps-8-per-second", "steps-30-per-second", "steps-2-per-second", "join-5", "join-20"].map((name) => [
        name,
        FIX,
      ]),
    ),
  });

  /** Presses the stage's `button` (outside the pane: the feed, not the cursor) `times` times, one
   *  every `every` painted frames. */
  const feed = async (page: Page, button: string, times: number, every: number) => {
    for (let i = 0; i < times; i++) {
      await page.evaluate((name) => document.querySelector<HTMLElement>(`[data-stage="${name}"]`)!.click(), button);
      await frames(page, every);
    }
  };

  /** How long a line must stay up to be read, and how many swaps a second a reader keeps up with:
   *  the calm the hat is held to (proposed; composer-hat-calm owns the number). */
  const READ_MS = 800;
  const SWAPS_PER_SECOND = 1.5;

  describe("feel: composer hat header", () => {
    for (const [name, every] of [
      ["8 steps a second", 7],
      ["30 steps a second", 2],
      ["2 steps a second", 30],
    ] as const)
      testFor(`steps-${name.split(" ")[0]}-per-second`)(
        `a subagent's steps at ${name}: the live line swaps at a reading pace, the header holds still`,
        async () => {
          const verdicts = await scenario(`steps-${name.split(" ")[0]}-per-second`, async (page, v) => {
            const trace = await record(page, SPEC, () => feed(page, "step", Math.ceil(180 / every), every), {
              settleFrames: 60,
            });
            const latest = churn(trace, "latest");
            const title = churn(trace, "title");
            const head = still(trace);
            v.atLeast("shortest time a live line stays up", latest.shortestHold, READ_MS, " ms");
            v.atMost("live line swaps per second", latest.swapsPerSecond, SWAPS_PER_SECOND);
            v.atMost("header name swaps", title.swaps, 0);
            v.atMost("live line width changes per second", latest.widthChangesPerSecond, 1);
            v.atMost("header moved", head.moved.head ?? 0, 1, " px");
            v.atMost("composer moved", head.moved.composer ?? 0, 1, " px");
            v.atMost("layout shift", head.shift, 0.01);
            return { latest, title, moved: head.moved, shift: head.shift };
          });
          expectPass(verdicts);
        },
      );

    for (const [name, times, every] of [
      ["five subagents join in a second", 5, 12],
      ["twenty join in a burst", 20, 1],
    ] as const)
      testFor(`join-${times}`)(`${name}: the header's words change at a reading pace and it holds still`, async () => {
        const verdicts = await scenario(`join-${times}`, async (page, v) => {
          const trace = await record(page, SPEC, () => feed(page, "join", times, every), { settleFrames: 60 });
          const title = churn(trace, "title");
          const more = churn(trace, "more");
          const head = still(trace);
          // The header's words may count what runs ("6 subagents running"), but at a reading pace:
          // twenty joining in a burst is one change a reader sees, not twenty.
          v.atLeast("shortest time the header's words stay up", title.shortestHold, READ_MS, " ms");
          v.atMost("header word swaps per second", title.swapsPerSecond, SWAPS_PER_SECOND);
          v.atMost("count's largest width step", more.maxWidthStep, 12, " px");
          v.atMost("header moved", head.moved.head ?? 0, 1, " px");
          v.atMost("composer moved", head.moved.composer ?? 0, 1, " px");
          v.atMost("layout shift", head.shift, 0.01);
          return { title, more, moved: head.moved, shift: head.shift };
        });
        expectPass(verdicts);
      });

    testFor("command-joins")("a command joins: the header changes once and holds still", async () => {
      const verdicts = await scenario("command-joins", async (page, v) => {
        const trace = await record(page, SPEC, () => feed(page, "command", 1, 1), { settleFrames: 60 });
        const title = churn(trace, "title");
        const head = still(trace);
        v.atMost("header word swaps", title.swaps, 1);
        v.atMost("header moved", head.moved.head ?? 0, 1, " px");
        v.atMost("layout shift", head.shift, 0.01);
        return { title, moved: head.moved, shift: head.shift };
      });
      expectPass(verdicts);
    });
  });
});
