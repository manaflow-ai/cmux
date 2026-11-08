// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A pane render that changes nothing the chat's header or Session Info shows renders neither, and a
// streamed reply's text delta renders neither (Leo, 2026-11-07: "im still seeing session info flash
// ... when im slowly scrolling down as you're doing the thinking/tool calls"). A running command's
// output alone no longer renders the pane (liveToolOutput.ts, agent-pane-tool-tick-pane-renders.test.ts);
// another chat in the list changing still does, once per change, and the header shows nothing of it
// and Session Info only its chat list (Usage), so the header keeps what it drew and Session Info's
// panel and sections do too. Measured before the fold (bench/delta-renders.bench.ts before
// liveToolOutput.ts, and this test at that head): the header rendered once per pane render.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with a light chat
// of 1,500 rows opened whole (`loadSeed(500, { light: true })`) and Session Info shown, then
// `loadTick` (one command whose output grows every 50 ms for three seconds while another chat in the
// list changes every 50 ms, nothing scrolled) and `loadRun` (one reply streamed in 24-character
// chunks every 12 ms for two seconds).
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

  test("a pane render that changes nothing they show renders neither the header nor Session Info", async () => {
    const { page, rows } = await openChat();
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 50, scroll_speed: 0 }),
    )) as Record<string, any>;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    const report = {
      rows,
      ticks: run.ticks,
      sidebar: run.sidebar,
      pane: renders.pane ?? 0,
      header: renders.header ?? 0,
      // The panel and its sections: the presence above them reads the chat list, which changed.
      sessionInfo: (renders["session-info:panel"] ?? 0) + (renders["session-info:sections"] ?? 0),
    };
    console.log(`PANE-RENDER-HEADER-SI-RENDERS ${JSON.stringify(report)}`);
    expect(report.rows).toBeGreaterThan(1000);
    expect(report.sidebar).toBeGreaterThan(30);
    // Each change in the list rendered the pane: the header and Session Info skipped renders it made.
    expect(report.pane).toBeGreaterThanOrEqual(report.sidebar);
    expect(report.header, "header renders over the pane's renders").toBeLessThanOrEqual(STRUCTURAL);
    expect(report.sessionInfo, "Session Info renders over the pane's renders").toBeLessThanOrEqual(STRUCTURAL);
  });

  test("an output update that draws through the pane renders neither the header nor Session Info", async () => {
    const { page } = await openChat();
    // Each line names #12: the pane reads a `#N` out of a call's output, so each update draws through
    // it, and Session Info lists the same #12 after the first.
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadTick({
        seconds: 3,
        tick_ms: 50,
        sidebar_ms: 0,
        scroll_speed: 0,
        line_suffix: " see #12",
      }),
    )) as Record<string, any>;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    const report = {
      ticks: run.ticks,
      pane: renders.pane ?? 0,
      header: renders.header ?? 0,
      sessionInfo: sessionInfo(renders),
    };
    console.log(`PANE-OUTPUT-HEADER-SI-RENDERS ${JSON.stringify(report)}`);
    expect(report.ticks).toBeGreaterThan(30);
    expect(report.pane).toBeGreaterThanOrEqual(report.ticks);
    expect(report.header, "header renders over the output updates").toBeLessThanOrEqual(STRUCTURAL);
    expect(report.sessionInfo, "Session Info renders over the output updates").toBeLessThanOrEqual(STRUCTURAL);
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
