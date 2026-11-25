// l10n-allow-file: test fixture rows, not shipped UI.
// A steer is a fold boundary: no row of the turn ever passes over the person's message, while the turn
// runs, while subagents start and end around it, and when the turn ends and its work folds. Leo,
// 2026-11-22 (ask-6cbe3d05b7): the fold animation swept rows up past his steer; (ask-22fd5d45f2):
// "crazy situation for the folding and whatever the steer and you think and messages and situations
// come in and subagents come in and out". Every painted frame of each scene is read in a real
// browser: a frame fails if any other row's box overlaps a steer's box, or a row that was drawn on one
// side of a steer is drawn on the other side in a later frame.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { playTurn, randomTurn, type GapEvent } from "./support/thinkingGapScenes";

type Box = { id: string; top: number; bottom: number; steer: boolean; ink: string };
type Frame = { step: string; boxes: Box[] };

await requireBrowserLane("steer-fold-boundary-browser.test.ts", async () => {
  const PAGE = "/test/browser/thinking-gap.html";
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch (e) {
    console.log("LAUNCHFAIL", String(e).slice(0, 800));
    describe.skip("steer fold boundary", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Plays the scene a step every `framesPerStep` painted frames, then 90 frames at rest (the
  /// turn-end fold's whole motion), and returns every frame's row boxes from the turn's prompt down.
  async function play(events: GapEvent[], framesPerStep = 12): Promise<Frame[]> {
    const steps = playTurn(events);
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}${PAGE}`);
      await page.waitForFunction(() => "__gap" in window);
      await page.evaluate(() => (window as unknown as { __gap: { loadStrings(): Promise<void> } }).__gap.loadStrings());
      return await page.evaluate(
        ({ steps, framesPerStep, ROW }) =>
          new Promise<Frame[]>((done) => {
            type Gap = { show(rows: unknown[], options?: { working?: boolean }): void };
            const gap = (window as unknown as { __gap: Gap }).__gap;
            const out: Frame[] = [];
            let frame = 0;
            let step = -1;
            window.cmuxAfterPaint(
              () => {
                const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
                if (scroller && step >= 0) {
                  const rows = [...scroller.querySelectorAll<HTMLElement>(ROW)]
                    .map((row) => ({ row, box: row.getBoundingClientRect() }))
                    .filter(({ box }) => box.height > 0)
                    .sort((a, b) => a.box.top - b.box.top);
                  const from = rows.findIndex(({ row }) => row.dataset.rowId === "prompt");
                  out.push({
                    step: steps[step]!.name,
                    boxes: (from < 0 ? [] : rows.slice(from)).map(({ row, box }) => ({
                      id: row.dataset.rowId ?? "",
                      top: box.top,
                      bottom: box.bottom,
                      steer: (row.dataset.rowId ?? "").startsWith("steer-"),
                      ink: (() => {
                        const style = getComputedStyle(row);
                        return `op=${style.opacity} tf=${style.transform} clip=${style.clipPath} anims=${row.getAnimations().length}`;
                      })(),
                    })),
                  });
                }
                frame += 1;
                if (frame >= steps.length * framesPerStep + 90) {
                  done(out);
                  return false;
                }
              },
              () => {
                if (frame % framesPerStep !== 0 || step >= steps.length - 1) return;
                step += 1;
                gap.show(steps[step]!.rows, { working: steps[step]!.working ?? true });
              },
            );
          }),
        { steps, framesPerStep, ROW: TRANSCRIPT_ROW },
      );
    } finally {
      await page.close();
    }
  }

  /// Every frame where a row's box overlaps a steer's, or a row changed sides of a steer since the
  /// last frame both were drawn in.
  function crossings(frames: Frame[]): string[] {
    const found: string[] = [];
    const side = new Map<string, "above" | "below">();
    for (const [index, frame] of frames.entries()) {
      for (const steer of frame.boxes.filter((box) => box.steer)) {
        for (const box of frame.boxes) {
          if (box.steer || box.id === steer.id) continue;
          const overlap = Math.min(box.bottom, steer.bottom) - Math.max(box.top, steer.top);
          if (overlap > 1)
            found.push(
              `frame ${index} ${frame.step}: ${box.id} overlaps ${steer.id} by ${overlap.toFixed(1)}px` +
                ` [${box.id} ${box.top.toFixed(1)}-${box.bottom.toFixed(1)} ${box.ink}]` +
                ` [${steer.id} ${steer.top.toFixed(1)}-${steer.bottom.toFixed(1)} ${steer.ink}]`,
            );
          const now = (box.top + box.bottom) / 2 < (steer.top + steer.bottom) / 2 ? "above" : "below";
          const key = `${steer.id}|${box.id}`;
          const was = side.get(key);
          if (was && was !== now)
            found.push(`frame ${index} ${frame.step}: ${box.id} moved ${was} -> ${now} ${steer.id}`);
          side.set(key, now);
        }
      }
    }
    return found;
  }

  const SCENES: Record<string, GapEvent[]> = {
    "work, a steer, more work, the turn ends": [
      { kind: "tool" },
      { kind: "finish" },
      { kind: "tool", tool: "read", title: "Read lanes.md", status: "completed" },
      { kind: "steer" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "reply", text: "Docs lane is green too.", streaming: false },
      { kind: "end" },
    ],
    "a subagent starts before the steer and ends after it": [
      { kind: "reply", text: "Starting a helper for lane 3.", streaming: false },
      { kind: "subagent" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "steer" },
      { kind: "subagentEnd" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "reply", text: "The helper is done and lane 3 landed.", streaming: false },
      { kind: "end" },
    ],
    "subagents come and go on both sides of two steers": [
      { kind: "subagent" },
      { kind: "subagent" },
      { kind: "tool" },
      { kind: "steer" },
      { kind: "subagentEnd", state: "disconnected" },
      { kind: "finish" },
      { kind: "subagent" },
      { kind: "message" },
      { kind: "thought", ended: true },
      { kind: "steer" },
      { kind: "subagentEnd" },
      { kind: "subagentEnd", state: "failed" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "reply", text: "Both helpers ended; one failed and waits on a retry.", streaming: false },
      { kind: "end" },
    ],
    "subagent ends burst in after the steer, right at turn end": [
      { kind: "subagent" },
      { kind: "subagent" },
      { kind: "subagent" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "steer" },
      { kind: "reply", text: "Checked the docs lane.", streaming: false },
      { kind: "subagentEnd", state: "disconnected" },
      { kind: "subagentEnd", state: "disconnected" },
      { kind: "subagentEnd" },
      { kind: "end" },
    ],
  };
  // Seeded fuzz turns, each forced to hold a steer, subagents both sides of it, and a turn end.
  for (const seed of [3, 11, 29]) {
    const middle = randomTurn(seed, 14);
    SCENES[`fuzz seed ${seed}`] = [
      { kind: "subagent" },
      ...middle.slice(0, 7),
      { kind: "steer" },
      { kind: "subagentEnd" },
      { kind: "subagent" },
      ...middle.slice(7),
      { kind: "subagentEnd" },
      { kind: "end" },
    ];
  }

  for (const [name, events] of Object.entries(SCENES))
    test(`${name}: no row passes over a steer in any painted frame`, async () => {
      const frames = await play(events);
      expect(frames.length).toBeGreaterThan(0);
      expect(frames.some((frame) => frame.boxes.some((box) => box.steer))).toBe(true);
      const bad = crossings(frames);
      console.log(`steer-fold-boundary ${name}: frames=${frames.length} crossings=${bad.length}`);
      expect(bad.slice(0, 6)).toEqual([]);
    });
});
