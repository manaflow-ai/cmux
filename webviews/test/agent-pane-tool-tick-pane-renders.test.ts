// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A running command's output update and a streamed text delta render neither the pane, nor its
// header, nor Session Info: none of them draws what changed (liveToolOutput.ts, streamingRow.ts).
// Leo, 2026-11-04: "Interaction cost stays constant as workspaces, sessions and panes grow: the
// visible window comes first" ("It should just never, ever ... be [freaking] acceptable for there
// to be some sort of linear time growth degradation"). Measured before (bench/delta-renders.bench.ts):
// 1.02 pane, 1.02 header and 1.05 Session Info renders per output update at 50 to 5,000 rows.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a light
// chat of 1,500 rows opened whole and Session Info shown, then `loadTick` (one command whose output
// grows every 50 ms for three seconds) and `loadRun` (one reply streamed in 24-character chunks).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tool-tick-pane-renders.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// What a stream's turn changes besides its deltas, each drawn a few times: its prompt, its start,
  /// a command's first output, its end and the chat's status in and out.
  const STRUCTURAL = 8;

  async function open(page: Page) {
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(500, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    expect(seeded.rows).toBeGreaterThan(1000);
    await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
    const toggle = page.locator("button.acpmux-session-info-toggle").first();
    await toggle.waitFor({ timeout: 10_000 });
    if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
    await page.waitForFunction(
      () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
    );
  }

  const counts = (renders: Record<string, number>) => ({
    pane: renders.pane ?? 0,
    header: renders.header ?? 0,
    sessionInfo:
      (renders["session-info:presence"] ?? 0) +
      (renders["session-info:panel"] ?? 0) +
      (renders["session-info:sections"] ?? 0),
  });

  test("output updates and text deltas render neither the pane, its header nor Session Info", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 820 } });
    await open(page);
    const tool = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 0, scroll_speed: 0 }),
    )) as Record<string, any>;
    const text = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 3,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 0,
        scroll_speed: 0,
      }),
    )) as Record<string, any>;
    await page.close();
    const report = {
      ticks: tool.ticks,
      tool: counts(tool.renders ?? {}),
      deltas: text.deltas,
      text: counts(text.renders ?? {}),
    };
    console.log(`PANE-RENDERS ${JSON.stringify(report)}`);
    expect(report.ticks).toBeGreaterThan(30);
    expect(report.deltas).toBeGreaterThan(30);
    for (const [stream, rendered] of [
      ["output updates", report.tool],
      ["text deltas", report.text],
    ] as const) {
      expect(rendered.pane, `pane renders over the ${stream}`).toBeLessThanOrEqual(STRUCTURAL);
      expect(rendered.header, `header renders over the ${stream}`).toBeLessThanOrEqual(STRUCTURAL);
      // Session Info counts three parts, each drawn with the pane.
      expect(rendered.sessionInfo, `Session Info renders over the ${stream}`).toBeLessThanOrEqual(3 * STRUCTURAL);
    }
  });
});
