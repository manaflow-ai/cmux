// l10n-allow-file: test fixture rows, not shipped UI.
// A steer that lands while a tool call runs leaves no extra blank band (Leo, 2026-11-22, ask-733d96d1c0:
// "a tool call in between. but it looks like there's \"extra\" spacing here. and my message presumably
// went... i dont know. the ordering here is really funky"). Every painted frame of each scene is read:
// the drawn distance between each two neighbouring rows that draw, which the grid keeps within one gap
// (24 px, plus rounding), and the order the steer, the calls and the replies appear in.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { playTurn, type GapEvent } from "./support/thinkingGapScenes";

type Frame = { step: string; worst: number; between: string; order: string };

await requireBrowserLane("steer-mid-tool-gap-browser.test.ts", async () => {
  const PAGE = "/test/browser/thinking-gap.html";
  // The largest block gap the grid puts between two rows (32 under a prompt), plus rounding.
  const MAX_GAP = 32.5;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("steer mid tool gap", () => test("chromium", () => {}));
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

  async function play(events: GapEvent[], framesPerStep = 12): Promise<Frame[]> {
    const steps = playTurn(events);
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
                  // Only the turn's own rows (after the long finished history), as laid out.
                  const from = rows.findIndex(({ row }) => row.dataset.rowId === "prompt");
                  const turn = from < 0 ? [] : rows.slice(from);
                  let worst = 0;
                  let between = "";
                  const pairs: string[] = [];
                  for (let i = 1; i < turn.length; i += 1) {
                    const gapPx = turn[i]!.box.top - turn[i - 1]!.box.bottom;
                    const above = turn[i - 1]!.row.dataset.rowId ?? "";
                    const below = turn[i]!.row.dataset.rowId ?? "";
                    pairs.push(`${above}>${below}=${Math.round(gapPx * 10) / 10}`);
                    // Only the gaps a steer touches: the rest are the grid's ordinary block gaps.
                    if ((above.startsWith("steer-") || below.startsWith("steer-")) && gapPx > worst) {
                      worst = gapPx;
                      between = `${above} -> ${below}`;
                    }
                  }
                  out.push({
                    step: steps[step]!.name,
                    worst: Math.round(worst * 10) / 10,
                    between,
                    order: pairs.join(" "),
                  });
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
                gap.show(steps[step]!.rows, { working: true });
              },
            );
          }),
        { steps, framesPerStep, ROW: TRANSCRIPT_ROW },
      );
    } finally {
      await page.close();
    }
  }

  const SCENES: Record<string, GapEvent[]> = {
    "steer while a call runs, then the call ends and a reply comes": [
      { kind: "reply", text: "I will check the lanes now.", streaming: false },
      { kind: "tool" },
      { kind: "steer" },
      { kind: "finish" },
      { kind: "reply", text: "Done with the lanes.", streaming: false },
    ],
    "steer while a call runs, a second call after it": [
      { kind: "reply", text: "I will check the lanes now.", streaming: false },
      { kind: "tool" },
      { kind: "steer" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "finish" },
    ],
    "steer between two calls of one run": [
      { kind: "tool" },
      { kind: "finish" },
      { kind: "steer" },
      { kind: "tool" },
      { kind: "finish" },
      { kind: "reply", text: "All of it is green.", streaming: false },
    ],
  };
  for (const [name, events] of Object.entries(SCENES))
    test(`${name}: no blank band between neighbouring rows`, async () => {
      const frames = await play(events);
      expect(frames.length).toBeGreaterThan(0);
      const top = frames.reduce((a, b) => (b.worst > a.worst ? b : a), frames[0]!);
      console.log(`steer-mid-tool-gap ${name}: max=${top.worst} ${JSON.stringify(top)}`);
      const over = frames.filter((frame) => frame.worst > MAX_GAP);
      expect(over.slice(0, 4).map((frame) => `${frame.step} ${frame.worst} ${frame.between} [${frame.order}]`)).toEqual(
        [],
      );
    });
});
