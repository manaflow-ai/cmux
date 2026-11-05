// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A streamed chunk of the reply re-renders the reply's row and nothing else (HOT PATH AUDIT area F,
// row W1, handoff/hot-path-audit/stream/AUDIT.md). Measured on the pane with a 2,000-row chat
// (Chrome 156, production React): every chunk re-rendered the whole pane (AcpmuxPane, ~20 memos over
// all rows), the composer and Session Info, 5-11 ms of React per frame, frames dropped at 2,000 rows.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a chat of 700
// heavy turns seeded through attach (`cmuxAcpmuxDebug.loadSeed`), then one text-only turn streamed
// at full speed (`loadRun`, no tool calls, no scrolling). Over the stream the pane root and the
// composer render no more often than the turn's own structural changes (its prompt, its start and
// its end), however many chunks land, and the reply's row renders once per drawn chunk.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-stream-renders.test.ts", async () => {
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

  /// Structural changes a streamed turn makes besides its chunks: its prompt, its start, its end,
  /// the summary's status in and out, and the frame its reply's row first appears. Renders past
  /// these are renders the chunks caused.
  const STRUCTURAL = 12;

  test("a streamed chunk re-renders only its row: not the pane, not the composer", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(700))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 4,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 0,
        scroll_speed: 0,
      }),
    )) as Record<string, any>;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    const rowRenders = Object.entries(renders).filter(([name]) => name.startsWith("row:"));
    const busiest = rowRenders.sort((a, b) => b[1] - a[1])[0] ?? ["none", 0];
    const report = {
      rows: run.rows,
      deltas: run.deltas,
      frames: run.frames,
      pane: renders.pane ?? 0,
      composer: renders.composer ?? 0,
      rowsRendered: rowRenders.length,
      streamingRow: busiest,
      liveLineHidden: run.live_line_hidden_frames,
      reactMs: run.react_ms,
      workMs: run.work_ms,
    };
    console.log(`STREAM-RENDERS ${JSON.stringify(report)}`);
    expect(run.deltas).toBeGreaterThan(100);
    // The reply's row drew the stream.
    expect(busiest[1]).toBeGreaterThan(20);
    expect(report.pane, "pane root renders during a text-only stream").toBeLessThanOrEqual(STRUCTURAL);
    expect(report.composer, "composer renders during a text-only stream").toBeLessThanOrEqual(STRUCTURAL);
    // The live line under the reply stays shown while it streams, reading "Writing": it never
    // leaves and comes back (Leo, 2026-11-04: "it appears and disappears????").
    expect(report.liveLineHidden, "frames with the live line hidden while the reply streams").toBe(0);
  });
});
