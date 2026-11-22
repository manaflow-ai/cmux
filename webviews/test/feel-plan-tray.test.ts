// Feel check: the composer hat's plan tray, dragged by its top rim (trayResize.ts, SubagentTray.tsx).
// Leo, 2026-11-22: "the dragging isn't properly relative accurate to the cursor, and it's just jumpy
// all over the place and doesn't have satisfying snap alongs ... errant clicks could make it jump",
// and "these should be doable via automation. the "feel" and "vibes" thing. you can simulate cursors
// clicking around."
//
// A simulated cursor (test/feel/cursor.ts) drags the rim slow, fast, shaky, in bursts and past the
// end and back, clicks it without dragging, misses it by a few px, double-clicks it, and drags it
// again and again; the probe (test/feel/probe.ts) reads every painted frame. Verdicts (numbers, not
// screenshots; test/feel/verdicts.ts):
// - the rim stays under the hand from the grab point, 1:1 (a frame of lag forgiven), with no jump;
// - it stays where it was let go, on a whole line (the snap: no line cut in half);
// - a shaky hand at the fold point folds or opens it once, not back and forth;
// - a click or a 3 px wobble on the rim, or a click just above it, moves and changes nothing;
// - a double-click moves the hat once, one way.
// The report and a recording per scenario go to $CMUX_FEEL_OUT/plan-tray (test/feel/report.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { click, doubleClick, drag, dragPath, play, type DragStyle } from "./feel/cursor";
import { frames, installFeelProbe, record } from "./feel/probe";
import { feelContext, feelDir, saveRecording, writeReport, type ScenarioResult } from "./feel/report";
import type { ProbeSpec } from "./feel/trace";
import { continuity, flips, follow, still, Verdicts } from "./feel/verdicts";

await requireBrowserLane("feel-plan-tray.test.ts", async () => {
  const ENTRY = "agent-pane.feel-plan-tray";
  const VARIANT = "fifty";
  const COMPONENT = "plan-tray";
  const VIEWPORT = { width: 480, height: 720 };
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("feel: plan tray", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const results: ScenarioResult[] = [];
  const dir = feelDir(COMPONENT);

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // A failed module fetch (a dev server still optimizing, a host's network blip) loads again.
    for (let attempt = 1; ; attempt++) {
      try {
        await warmGalleryFrame(vite, [ENTRY], { browser, params: { variant: VARIANT } });
        break;
      } catch (error) {
        if (attempt === 3 || !/Failed to fetch dynamically imported module/.test(String(error))) throw error;
      }
    }
  }, 120_000);
  afterAll(async () => {
    const report = writeReport(COMPONENT, results);
    console.log(report);
    await browser?.close();
    await vite?.close();
  });

  const TRAY = ".acpmux-running-tray";
  const RIM = ".acpmux-running-tray__rim";
  const LIST = ".acpmux-running-tray__list";
  const SPEC: ProbeSpec = {
    boxes: {
      tray: TRAY,
      rim: RIM,
      list: LIST,
      plan: ".acpmux-running-tray__plan",
      head: ".acpmux-running-tray__head",
      composer: ".acpmux-composer",
    },
    states: { open: { selector: TRAY, attr: "data-open" } },
  };

  const open = async (variant: string = VARIANT): Promise<Page> => {
    const context = await feelContext(browser!, dir, VIEWPORT);
    const page = await context.newPage();
    await installFeelProbe(page);
    const url = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant })}`;
    for (let attempt = 1; ; attempt++) {
      await page.goto(url);
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        break;
      } catch (error) {
        if (attempt === 3 || !/context was destroyed|navigat|Timeout/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => {
      localStorage.removeItem("cmux.agentPane.hatListHeight");
      return document.fonts.ready;
    });
    await page.waitForSelector(`${TRAY}[data-open] ${LIST}`);
    await page.mouse.move(2, 2);
    // The open's fold has run: nothing animates.
    await page.waitForFunction(() =>
      document.getAnimations().every((a) => a.playState !== "running" || a.effect?.getTiming().iterations === Infinity),
    );
    await frames(page, 4);
    return page;
  };

  /** Where a hand grabs the rim: its middle band, a third of the way in (the tuck chevron sits over
   *  its centre and keeps its own clicks; `rimMiddle` is that point). */
  const rimCentre = async (page: Page) => {
    const box = (await page.locator(RIM).boundingBox())!;
    return { x: box.x + box.width / 3, y: box.y + box.height / 2, box };
  };
  const rimMiddle = async (page: Page) => {
    const box = (await page.locator(RIM).boundingBox())!;
    return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  };

  /** The list's line pitch: the distance between its first two lines' tops. */
  const pitch = (page: Page) =>
    page.evaluate((list) => {
      const lines = [...document.querySelector(list)!.children].map((child) => child.getBoundingClientRect());
      const tops = lines.map((rect) => rect.top).filter((top, i, all) => i === 0 || top - all[i - 1]! > 4);
      return tops.length > 1 ? tops[1]! - tops[0]! : 28;
    }, LIST);

  const scenario = async (name: string, run: (page: Page, verdicts: Verdicts) => Promise<Record<string, unknown>>) => {
    const page = await open();
    const verdicts = new Verdicts();
    let numbers: Record<string, unknown> = {};
    try {
      numbers = await run(page, verdicts);
    } finally {
      const video = await saveRecording(page, dir, name);
      await page.context().close();
      results.push({ scenario: name, verdicts: verdicts.list, numbers, video });
    }
    return verdicts;
  };

  const expectPass = (verdicts: Verdicts) =>
    expect(verdicts.failed.map((v) => `${v.check}: ${v.measured} (limit ${v.limit})`)).toEqual([]);

  /** A drag of the rim by `dy` px (negative: up) in `style`, judged on the tray's top edge. */
  const dragScenario = (style: DragStyle, dy: number) =>
    test(`drag ${style} ${dy < 0 ? "up" : "down"} ${Math.abs(dy)} px: the rim stays under the hand, no jump, lands on a line`, async () => {
      const verdicts = await scenario(`drag-${style}-${dy}`, async (page, v) => {
        const { x, y } = await rimCentre(page);
        const line = await pitch(page);
        const trace = await record(page, SPEC, () => drag(page, { x, y }, dragPath({ x, y }, { x, y: y + dy }, style)));
        const report = follow(trace, { box: "tray", edge: "top", slop: 8 });
        v.atMost("rim offset from the grab point (max)", report.maxError, 3, " px");
        v.atMost("jumps (frames off the hand by over 4 px)", report.jumps.length, 0);
        v.atMost("move after release", report.releaseMove, 1, " px");
        const list = trace.frames.at(-1)!.boxes.list;
        if (list) {
          const off = Math.abs(list.h / line - Math.round(list.h / line)) * line;
          v.atMost(`list lands on a whole line (pitch ${Math.round(line)} px)`, off, 2, " px");
        }
        return { ...report, pitch: line, listHeight: list?.h };
      });
      expectPass(verdicts);
    });

  describe("feel: plan tray rim drag", () => {
    dragScenario("slow", -60);
    dragScenario("fast", -60);
    dragScenario("jitter", -60);
    dragScenario("burst", -60);
    dragScenario("slow", 40);

    test("past the end and back: the rim waits at its limit and picks up again under the hand", async () => {
      const verdicts = await scenario("overshoot", async (page, v) => {
        const { x, y } = await rimCentre(page);
        const trace = await record(page, SPEC, () =>
          drag(page, { x, y }, dragPath({ x, y }, { x, y: Math.max(20, y - 420) }, "overshoot")),
        );
        const report = follow(trace, { box: "tray", edge: "top", slop: 8 });
        v.atMost("rim offset from the grab point (max)", report.maxError, 3, " px");
        v.atMost("jumps", report.jumps.length, 0);
        v.atMost("move after release", report.releaseMove, 1, " px");
        return report;
      });
      expectPass(verdicts);
    });

    test("a shaky hand at the fold point folds it once, not back and forth", async () => {
      const verdicts = await scenario("fold-hysteresis", async (page, v) => {
        const { x, y } = await rimCentre(page);
        const list = (await page.locator(LIST).boundingBox())!;
        // Down to where the list would be 10 px tall (the fold is under half a line), then ±10 px
        // around it eight times.
        const fold = y + list.height - 10;
        const trace = await record(page, SPEC, async () => {
          await page.mouse.move(x, y);
          await page.mouse.down();
          await play(page, dragPath({ x, y }, { x, y: fold }, "slow"));
          for (let i = 0; i < 8; i++) await play(page, [{ x, y: fold + (i % 2 ? 10 : -10), wait: 2 }]);
          await page.mouse.up();
        });
        const changes = flips(trace, "open");
        v.atMost("open/fold changes", changes, 1);
        return { flips: changes };
      });
      expectPass(verdicts);
    });

    for (const [name, wobble] of [
      ["click", 0],
      ["wobble-3px", 3],
    ] as const)
      test(`a ${name} on the rim (no drag) moves and changes nothing`, async () => {
        const verdicts = await scenario(`rim-${name}`, async (page, v) => {
          const { x, y } = await rimCentre(page);
          const trace = await record(page, SPEC, () => click(page, { x, y }, { wobble }));
          const report = still(trace);
          v.atMost("tray moved", report.moved.tray ?? 0, 1, " px");
          v.atMost("composer moved", report.moved.composer ?? 0, 1, " px");
          v.equals("open state", report.changed.open, ["true"]);
          return report;
        });
        expectPass(verdicts);
      });

    test("a click 3 px above the rim (a miss) moves and changes nothing", async () => {
      const verdicts = await scenario("miss-above", async (page, v) => {
        const { x, box } = await rimCentre(page);
        const trace = await record(page, SPEC, () => click(page, { x, y: box.y - 3 }));
        const report = still(trace);
        v.atMost("tray moved", report.moved.tray ?? 0, 1, " px");
        v.equals("open state", report.changed.open, ["true"]);
        return report;
      });
      expectPass(verdicts);
    });

    test("a double-click on the rim moves the hat once, one way", async () => {
      const verdicts = await scenario("double-click", async (page, v) => {
        // Sized first, so the double-click's reset to five lines has somewhere to go.
        const { x, y } = await rimCentre(page);
        await drag(page, { x, y }, dragPath({ x, y }, { x, y: y - 40 }, "slow"));
        await frames(page, 20);
        const rim = await rimCentre(page);
        const trace = await record(page, SPEC, () => doubleClick(page, rim));
        const motion = continuity(trace, "tray", "top");
        v.atMost("separate moves", motion.moves, 1);
        v.atMost("reversals", motion.reversals, 0);
        v.equals("open state", still(trace).changed.open, ["true"]);
        return motion;
      });
      expectPass(verdicts);
    });

    test("five drags in a row, up and down: each follows the hand, none jumps", async () => {
      const verdicts = await scenario("repeat", async (page, v) => {
        let worst = 0;
        let jumps = 0;
        for (const dy of [-30, 30, -50, 20, -10]) {
          const { x, y } = await rimCentre(page);
          const trace = await record(
            page,
            SPEC,
            () => drag(page, { x, y }, dragPath({ x, y }, { x, y: y + dy }, "slow")),
            {
              settleFrames: 6,
            },
          );
          const report = follow(trace, { box: "tray", edge: "top", slop: 8 });
          worst = Math.max(worst, report.maxError);
          jumps += report.jumps.length;
        }
        v.atMost("rim offset from the grab point (worst of five)", worst, 3, " px");
        v.atMost("jumps (all five)", jumps, 0);
        return { worst, jumps };
      });
      expectPass(verdicts);
    });
  });
});
