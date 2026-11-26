// cmux-web-test-timeout: 420
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A streamed chunk of the reply re-renders the reply's row and nothing else (HOT PATH AUDIT area F,
// row W1, handoff/hot-path-audit/stream/AUDIT.md). Measured on the pane with a 2,000-row chat
// (Chrome 156, production React): every chunk re-rendered the whole pane (AcpmuxPane, ~20 memos over
// all rows), the composer and Session Info, 5-11 ms of React per frame, frames dropped at 2,000 rows.
//
// The same for a thought's chunk and a status change alone (Leo, 2026-11-16: "but typing under load
// is not good enough"): each rendered the pane root once (bench/delta-renders.bench.ts: 1.0 and 1.03
// per event), and each reply or thought chunk rendered the whole transcript about twice, which copied
// its rows each time (1.9 to 2.2 per chunk).
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a chat of 700
// heavy turns seeded through attach (`cmuxAcpmuxDebug.loadSeed`), then one turn streamed at full
// speed (`loadRun`, no tool calls, no scrolling) of each kind: reply text, a thought, and usage
// updates alone. Over the stream the pane root renders no more often than the turn's own structural
// changes (its prompt, its start and its end), however many chunks land; the transcript renders for
// a row's height (a new line), not per chunk; the row that streams renders once per drawn chunk.
//
// The transcript itself gets the same bound, one render per chunk: a chunk gives it new rows, so it
// draws, but it must not draw that chunk twice. It did, about 2.6 times per streamed event
// (`transcript_per_stream_event`, composer-typing.bench.ts, cmux#45237), because a render-phase
// setState took a row snapshot on every row change; a keystroke's frame then queued behind both
// passes (Leo, 2026-11-17: "slow and sad comparatively on the latter").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { SESSION_INFO, SESSION_INFO_TOGGLE } from "../src/agent-session/acpmux/session-info/sessionInfoSelectors";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-stream-renders.test.ts", async () => {
  setDefaultTimeout(400_000);
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

  for (const kind of ["text", "thought", "status"] as const)
    test(`a streamed ${kind} chunk re-renders only its row: not the pane, not the transcript`, async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/?mock`);
      await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
      // As bench/delta-renders.bench.ts sets it up: a light chat opened whole, with Session Info shown,
      // whose usage readers a status update reaches.
      const seeded = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadSeed(700, { light: true }),
      )) as Record<string, any>;
      expect(seeded.error).toBeUndefined();
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
      const toggle = page.locator(SESSION_INFO_TOGGLE).first();
      await toggle.waitFor({ timeout: 10_000 });
      if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
      await page.waitForFunction(
        (panel) => document.querySelector(panel)?.getAttribute("data-presence") === "shown",
        SESSION_INFO,
      );
      const run = (await page.evaluate(
        (kind) =>
          (window as any).cmuxAcpmuxDebug.loadRun({
            seconds: 4,
            chunk_chars: 24,
            chunk_ms: 12,
            tool_every: 0,
            scroll_speed: 0,
            stream_kind: kind,
          }),
        kind,
      )) as Record<string, any>;
      await page.close();
      const renders = (run.renders ?? {}) as Record<string, number>;
      // A row's content (VirtualTranscript.tsx RowContent, `content:<id>`) is what draws a streamed
      // chunk; its frame (`row:<id>`) renders for its place and height.
      const rowRenders = Object.entries(renders).filter(([name]) => name.startsWith("content:"));
      const busiest = rowRenders.sort((a, b) => b[1] - a[1])[0] ?? ["none", 0];
      const report = {
        kind,
        rows: run.rows,
        deltas: run.deltas,
        frames: run.frames,
        pane: renders.pane ?? 0,
        transcript: renders.transcript ?? 0,
        composer: renders.composer ?? 0,
        rowsRendered: rowRenders.length,
        streamingRow: busiest,
        liveLineHidden: run.live_line_hidden_frames,
        reactMs: run.react_ms,
        workMs: run.work_ms,
      };
      console.log(`STREAM-RENDERS ${JSON.stringify(report)}`);
      expect(run.deltas).toBeGreaterThan(100);
      expect(report.pane, `pane root renders during a ${kind} stream`).toBeLessThanOrEqual(STRUCTURAL);
      if (kind === "status") {
        // Nothing in the transcript draws the usage numbers.
        expect(report.transcript, "transcript renders during usage updates").toBeLessThanOrEqual(STRUCTURAL);
        return;
      }
      // The streaming row drew the stream.
      expect(busiest[1]).toBeGreaterThan(20);
      // The transcript renders when a row's height changes (a new line, which the reply's reveal
      // moves frame by frame), never for the chunk itself: before, each chunk rendered it about twice
      // (bench/delta-renders.bench.ts: 1.9 to 2.2 per chunk), once to copy its rows.
      expect(report.transcript, `transcript renders during a ${kind} stream`).toBeLessThanOrEqual(
        STRUCTURAL + run.deltas,
      );
      expect(report.composer, `composer renders during a ${kind} stream`).toBeLessThanOrEqual(STRUCTURAL);
      // The live line under the reply stays shown while it streams, reading "Writing": it never
      // leaves and comes back (Leo, 2026-11-04: "it appears and disappears????").
      if (kind === "text")
        expect(report.liveLineHidden, "frames with the live line hidden while the reply streams").toBe(0);
    });
});
