// cmux-web-test-timeout: 600
// The chat simulator's narrow-pane spacing rule (src/agent-session/acpmux/sim/README.md): every scenario
// drawn to its end in Chrome by the real VirtualTranscript with the pane's CSS (browser/chat-sim.harness.tsx),
// at 720 px and at 280 px. The gap over every drawn one-line row (a step, a status line, "Worked for") and
// over the row right under one is the same at both widths, and a one-line row stays one line: a narrow
// pane changes how much of a line's words show, never the rhythm between the lines (Leo, 2026-11-22, on a
// narrow pane: "maybe it's cuz the folding and tool calling and spacing got fucked up").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Browser, Page } from "playwright";
import { scenarioNames } from "../src/agent-session/acpmux/sim/scenarios";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type StepBox = { id: string; line: boolean; top: number; bottom: number };
const NARROW_WIDTHS = { wide: 720, narrow: 280 } as const;
const round = (px: number) => Math.round(px * 10) / 10;

await requireBrowserLane("chat-sim-narrow-browser.test.ts", async () => {
  const PAGE = "/test/browser/chat-sim.html";
  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  const { chromium } = await import("playwright");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let page: Page | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      mode: "production",
      define: { "process.env.NODE_ENV": JSON.stringify("production") },
      cacheDir: path.join(webviews, "node_modules/.vite-chat-sim"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    const { port } = vite.httpServer!.address() as { port: number };
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 760, height: 1400 } });
    page.on("pageerror", (error) => console.error(`chat-sim page: ${error.message}`));
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
    await page.waitForFunction(() => "__chatSim" in window);
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** `name` played at `width`: each step's drawn rows, top to bottom. */
  const stepsAt = async (name: string, width: number): Promise<StepBox[][]> =>
    (await page!.evaluate(
      async ([name, width]) => {
        const sim = (
          window as unknown as {
            __chatSim: { setWidth(px: number): void; boxes(name: string): Promise<unknown> };
          }
        ).__chatSim;
        sim.setWidth(width);
        return sim.boxes(name);
      },
      [name, width] as const,
    )) as StepBox[][];

  /** At one step: the gap over each drawn row that is a one-line row or sits right under one, and a line's height. */
  const lineGaps = (step: StepBox[]) => {
    const out = new Map<string, { gap: number; height: number; line: boolean; above: string }>();
    step.forEach((box, index) => {
      const above = step[index - 1];
      if (!above || (!box.line && !above.line)) return;
      out.set(box.id, {
        gap: round(box.top - above.bottom),
        height: round(box.bottom - box.top),
        line: box.line,
        above: above.id,
      });
    });
    return out;
  };

  const names = process.env.CHAT_SIM_SCENARIOS?.split(",") ?? scenarioNames();
  for (const name of names)
    test(`chat simulator in Chrome: ${name}: one-line rows keep their gaps at ${NARROW_WIDTHS.narrow} px as at ${NARROW_WIDTHS.wide} px`, async () => {
      const wide = await stepsAt(name, NARROW_WIDTHS.wide);
      const narrow = await stepsAt(name, NARROW_WIDTHS.narrow);
      expect(narrow.length).toBe(wide.length);
      const off = new Set<string>();
      let pairs = 0;
      wide.forEach((step, index) => {
        const at720 = lineGaps(step);
        const at280 = lineGaps(narrow[index] ?? []);
        for (const [id, w] of at720) {
          const n = at280.get(id);
          if (!n || n.above !== w.above) continue;
          pairs += 1;
          if (Math.abs(n.gap - w.gap) > 0.5) off.add(`${id}: gap ${w.gap} wide, ${n.gap} narrow (under ${w.above})`);
          if (w.line && Math.abs(n.height - w.height) > 0.5)
            off.add(`${id}: one-line row ${w.height} tall wide, ${n.height} narrow`);
        }
      });
      console.log(`${name}: ${pairs} line gaps compared, ${off.size} differ`);
      expect([...off]).toEqual([]);
    });
});
