// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A running command's output update re-renders no part of the transcript that does not show it
// (Leo, 2026-11-07: "if we think about our app (the agent chat/whatever) part of it like 'a
// website' then we can think about react and next.js..."). The update reaches the pane (its rows
// feed what reads a call's output: the header's Preview, Session Info), but the transcript draws
// the same rows before and after it, so the transcript (VirtualTranscript) and its rows keep what
// they drew. Measured before the fix (bench/delta-renders.bench.ts): 1.07 transcript renders per
// output update at 75, 750 and 7,500 rows.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a light
// chat of 1,500 rows opened whole (`loadSeed(500, { light: true })`), then `loadTick`: one command
// whose output grows every 50 ms for three seconds, no other chat changing, nothing scrolled.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tool-tick-transcript-renders.test.ts", async () => {
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

  /// What the command's turn changes in the transcript besides its output, each drawn a few times:
  /// its prompt, its start, the call's row appearing, its end and the chat's status in and out.
  const STRUCTURAL = 12;

  test("a running command's output update renders neither the transcript nor its rows", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 820 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(500, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    expect(seeded.rows).toBeGreaterThan(1000);
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 0, scroll_speed: 0 }),
    )) as Record<string, any>;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    // A row draws when its turn's structure moves it (a few times at most), never once per update.
    const busiestRow = Object.entries(renders)
      .filter(([name]) => name.startsWith("row:"))
      .sort((a, b) => b[1] - a[1])[0] ?? ["none", 0];
    const report = {
      rows: seeded.rows,
      ticks: run.ticks,
      pane: renders.pane ?? 0,
      transcript: renders.transcript ?? 0,
      busiestRow,
    };
    console.log(`TOOL-TICK-RENDERS ${JSON.stringify(report)}`);
    expect(report.ticks).toBeGreaterThan(30);
    expect(report.transcript, "transcript renders over the command's output updates").toBeLessThanOrEqual(STRUCTURAL);
    expect(busiestRow[1], `renders of ${busiestRow[0]} over the command's output updates`).toBeLessThanOrEqual(
      STRUCTURAL,
    );
  });
});
