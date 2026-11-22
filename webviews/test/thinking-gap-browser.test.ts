// l10n-allow-file: test fixture rows, not shipped UI.
// While a turn runs, the Thinking line sits one gap under the last row over it that draws: 8 under a
// step row, 8 under a reply, at most 24 under anything else (transcriptGrid.ts transcriptGap). Leo saw
// a much larger gap there in a long Claude Code coordinator chat ("we can't afford to have these thrown
// together"). Every painted frame of each scene is read: the drawn distance from the bottom of the last
// row that draws to the top of the Thinking line, its layout distance, and the rows between them.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { playTurn, randomTurn, type GapEvent, type Step } from "./support/thinkingGapScenes";

type Frame = {
  step: string;
  gap: number;
  layoutGap: number;
  above: string;
  aboveHeight: number;
  between: string[];
  lineTranslate: string;
  aboveTranslate: string;
};

await requireBrowserLane("thinking-gap-browser.test.ts", async () => {
  const PAGE = "/test/browser/thinking-gap.html";
  /// The largest gap the grid puts over the live line (a card or another row's block gap), plus rounding.
  const MAX_GAP = 24.5;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thinking-gap-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("the Thinking line gap", () => test("chromium", () => {}));
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

  async function play(steps: Step[], framesPerStep = 12): Promise<Frame[]> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}${PAGE}`);
      await page.waitForFunction(() => "__gap" in window);
      await page.evaluate(() => (window as unknown as { __gap: { loadStrings(): Promise<void> } }).__gap.loadStrings());
      return await page.evaluate(
        ({ steps, framesPerStep, ROW }) =>
          new Promise<Frame[]>((done) => {
            type Gap = { show(rows: unknown[], options?: { working?: boolean; width?: number }): void };
            const gap = (window as unknown as { __gap: Gap }).__gap;
            const out: Frame[] = [];
            let frame = 0;
            let step = -1;
            const translate = (node: HTMLElement) => getComputedStyle(node).translate;
            window.cmuxAfterPaint(
              () => {
                const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
                const line = document.querySelector<HTMLElement>(`${ROW.slice(0, -1)}="thinking-live"]`);
                if (scroller && line && step >= 0) {
                  const box = line.getBoundingClientRect();
                  let above: HTMLElement | undefined;
                  let aboveBottom = -Infinity;
                  const rows = [...scroller.querySelectorAll<HTMLElement>(ROW)];
                  for (const row of rows) {
                    if (row === line) continue;
                    const r = row.getBoundingClientRect();
                    if (r.height <= 0 || r.bottom > box.top + 0.5) continue;
                    if (r.bottom > aboveBottom) {
                      aboveBottom = r.bottom;
                      above = row;
                    }
                  }
                  if (above) {
                    const lineAt = rows.indexOf(line);
                    const aboveAt = rows.indexOf(above);
                    const between = rows
                      .slice(Math.min(lineAt, aboveAt) + 1, Math.max(lineAt, aboveAt))
                      .map(
                        (row) =>
                          `${row.dataset.rowId}@${row.style.top}/${row.getBoundingClientRect().height.toFixed(1)}`,
                      );
                    out.push({
                      step: steps[step]!.name,
                      gap: Math.round((box.top - aboveBottom) * 10) / 10,
                      layoutGap: Math.round((line.offsetTop - (above.offsetTop + above.offsetHeight)) * 10) / 10,
                      above: `${above.dataset.rowId}@${above.style.top}`,
                      aboveHeight: Math.round(above.getBoundingClientRect().height * 10) / 10,
                      between,
                      lineTranslate: translate(line),
                      aboveTranslate: translate(above),
                    });
                  }
                }
                frame += 1;
                if (frame >= steps.length * framesPerStep + 30) {
                  done(out);
                  return false;
                }
              },
              () => {
                if (frame % framesPerStep !== 0 || step >= steps.length - 1) return;
                step += 1;
                const next = steps[step]!;
                gap.show(next.rows, { working: true, ...(next.width !== undefined && { width: next.width }) });
                const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
                if (scroller && next.scroll === "up") {
                  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -120, bubbles: true, cancelable: true }));
                  scroller.scrollTop -= 120;
                }
                if (scroller && next.scroll === "down") {
                  const end = scroller.scrollHeight - scroller.clientHeight;
                  scroller.dispatchEvent(
                    new WheelEvent("wheel", { deltaY: end - scroller.scrollTop, bubbles: true, cancelable: true }),
                  );
                  scroller.scrollTop = end;
                }
              },
            );
          }),
        { steps, framesPerStep, ROW: TRANSCRIPT_ROW },
      );
    } finally {
      await page.close();
    }
  }

  const worst = (frames: Frame[]) => frames.reduce((a, b) => (b.gap > a.gap ? b : a), frames[0]!);
  const report = (name: string, frames: Frame[]) => {
    const over = frames.filter((frame) => frame.gap > MAX_GAP);
    const top = worst(frames);
    console.log(
      `thinking-gap ${name}: frames=${frames.length} over=${over.length} max=${top?.gap} ${JSON.stringify(top)}`,
    );
    for (const frame of over.slice(0, 6)) console.log(`  over ${JSON.stringify(frame)}`);
    return over;
  };

  const SCENES: Record<string, GapEvent[]> = {
    "calls folding into runs": [
      { kind: "thought" },
      { kind: "thought", ended: true },
      ...Array.from({ length: 6 }, (): GapEvent[] => [{ kind: "tool" }, { kind: "finish" }]).flat(),
      { kind: "reply" },
      { kind: "reply", streaming: false },
      ...Array.from({ length: 4 }, (): GapEvent[] => [{ kind: "tool" }, { kind: "finish" }]).flat(),
    ],
    "discovery call last": [
      { kind: "tool" },
      { kind: "finish" },
      { kind: "toolSearch" },
      { kind: "toolSearch", fresh: true },
      { kind: "toolSearch" },
    ],
    // Leo's screenshot (2026-11-21): a closed "Ran 3 commands", then thought and command rows in turn, Thinking under.
    "closed run then thought and command rows": [
      { kind: "message" },
      ...Array.from({ length: 3 }, (): GapEvent[] => [{ kind: "tool" }, { kind: "finish" }]).flat(),
      ...Array.from({ length: 3 }, (): GapEvent[] => [
        { kind: "thought" },
        { kind: "thought", ended: true },
        { kind: "tool" },
        { kind: "finish" },
      ]).flat(),
    ],
    "wrap_up last": [{ kind: "tool" }, { kind: "finish" }, { kind: "mcp" }, { kind: "wrapUp" }],
    "wrap_up own row": [{ kind: "tool" }, { kind: "finish" }, { kind: "wrapUp", fresh: true }],
    "steer and message": [
      { kind: "tool" },
      { kind: "finish" },
      { kind: "steer" },
      { kind: "tool" },
      { kind: "message" },
      { kind: "finish" },
      { kind: "message" },
    ],
    "background task": [{ kind: "tool" }, { kind: "finish" }, { kind: "background" }, { kind: "tool" }],
    "width change": [
      { kind: "tool" },
      { kind: "finish" },
      { kind: "width", px: 620 },
      { kind: "tool" },
      { kind: "width", px: 860 },
      { kind: "finish" },
    ],
    "reader scrolls up and back": [
      { kind: "tool" },
      { kind: "finish" },
      { kind: "scroll", to: "up" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "scroll", to: "down" },
      { kind: "tool" },
    ],
  };
  for (const [name, events] of Object.entries(SCENES))
    test(`${name}: the Thinking line stays one gap under the last drawn row`, async () => {
      const frames = await play(playTurn(events));
      expect(frames.length).toBeGreaterThan(0);
      const over = report(name, frames);
      expect(over.map((frame) => `${frame.step} ${frame.gap}`)).toEqual([]);
    });

  // CMUX_GAP_SWEEP=N: N more seeded turns of 60 events, each frame's gap summarized (no assertion).
  test.skipIf(!process.env.CMUX_GAP_SWEEP)("sweep (CMUX_GAP_SWEEP)", async () => {
    const counts = new Map<number, number>();
    for (let seed = 100; seed < 100 + Number(process.env.CMUX_GAP_SWEEP); seed += 1) {
      const frames = await play(playTurn(randomTurn(seed, 60)), 6);
      for (const frame of frames) counts.set(Math.round(frame.gap), (counts.get(Math.round(frame.gap)) ?? 0) + 1);
      const over = frames.filter((frame) => frame.gap > MAX_GAP);
      const kinds = new Set(
        over.map(
          (frame) =>
            `${frame.step.replace(/^\d+:/, "")} gap ${frame.gap} above ${frame.above.replace(/-\d+@.*/, "")} between ${frame.between.map((b) => b.replace(/-\d+@[^/]*/, "")).join(",")}`,
        ),
      );
      if (over.length)
        console.log(`sweep seed ${seed}: over=${over.length} max=${worst(frames).gap} ${[...kinds].join(" | ")}`);
    }
    console.log(`sweep gaps: ${JSON.stringify([...counts].sort((a, b) => a[0] - b[0]))}`);
  });

  for (const seed of [1, 2, 3, 4, 5, 6])
    test(`random coordinator turn ${seed}: the Thinking line stays one gap under the last drawn row`, async () => {
      const frames = await play(playTurn(randomTurn(seed, 40)), 8);
      expect(frames.length).toBeGreaterThan(0);
      const over = report(`random ${seed}`, frames);
      expect(over.map((frame) => `${frame.step} ${frame.gap}`)).toEqual([]);
    });
});
