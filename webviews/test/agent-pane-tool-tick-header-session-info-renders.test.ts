// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A running command's output update and a streamed reply's text delta render neither the chat's
// header nor Session Info, unless what they show changed (Leo, 2026-11-07: "im still seeing session
// info flash ... when im slowly scrolling down as you're doing the thinking/tool calls"). The update
// reaches the pane, whose rows feed what the header and Session Info show, but neither shows a
// command's output, so both keep what they drew. Measured before the fix
// (bench/delta-renders.bench.ts): 1.02 header renders and 1.05 Session Info renders per output
// update at 51, 501 and 5,001 rows.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a light chat
// of 1,500 rows opened whole (`loadSeed(500, { light: true })`) and Session Info shown, then
// `loadTick` (one command whose output grows every 50 ms for three seconds, nothing scrolled) and
// `loadRun` (one reply streamed in 24-character chunks every 12 ms for two seconds).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tool-tick-header-session-info-renders.test.ts", async () => {
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

  /// What the turn changes that the header and Session Info show, each drawn a few times: its
  /// prompt, its start, the call's row appearing, its end and the chat's status in and out.
  const STRUCTURAL = 12;

  async function openChat(): Promise<{ page: Page; rows: number }> {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 820 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadSeed(500, { light: true }),
    )) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
    const toggle = page.locator("button.acpmux-session-info-toggle").first();
    await toggle.waitFor({ timeout: 10_000 });
    if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
    await page.waitForFunction(
      () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
    );
    return { page, rows: seeded.rows as number };
  }

  const sessionInfo = (renders: Record<string, number>) =>
    (renders["session-info:presence"] ?? 0) +
    (renders["session-info:panel"] ?? 0) +
    (renders["session-info:sections"] ?? 0);

  test("a running command's output update renders neither the header nor Session Info", async () => {
    const { page, rows } = await openChat();
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 0, scroll_speed: 0 }),
    )) as Record<string, any>;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    const report = {
      rows,
      ticks: run.ticks,
      pane: renders.pane ?? 0,
      header: renders.header ?? 0,
      sessionInfo: sessionInfo(renders),
    };
    console.log(`TOOL-TICK-HEADER-SI-RENDERS ${JSON.stringify(report)}`);
    expect(report.rows).toBeGreaterThan(1000);
    expect(report.ticks).toBeGreaterThan(30);
    // Each update reached the pane: the header and Session Info skipped renders their parent made.
    expect(report.pane).toBeGreaterThanOrEqual(report.ticks);
    expect(report.header, "header renders over the command's output updates").toBeLessThanOrEqual(STRUCTURAL);
    expect(report.sessionInfo, "Session Info renders over the command's output updates").toBeLessThanOrEqual(
      STRUCTURAL,
    );
  });

  test("a streamed reply's text deltas render neither the header nor Session Info", async () => {
    const { page } = await openChat();
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 2,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 0,
        scroll_speed: 0,
      }),
    )) as Record<string, any>;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    const report = { deltas: run.deltas, header: renders.header ?? 0, sessionInfo: sessionInfo(renders) };
    console.log(`TEXT-DELTA-HEADER-SI-RENDERS ${JSON.stringify(report)}`);
    expect(report.deltas).toBeGreaterThan(30);
    expect(report.header, "header renders over the reply's text deltas").toBeLessThanOrEqual(STRUCTURAL);
    expect(report.sessionInfo, "Session Info renders over the reply's text deltas").toBeLessThanOrEqual(STRUCTURAL);
  });
});
