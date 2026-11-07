// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// Scrolling draws Session Info no more than once (Leo, 2026-11-06, of the transcript's scroll redraws:
// "I think we should have it be, like, the same for the session info").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with Session Info
// open, a chat of 300 heavy turns seeded through attach (`cmuxAcpmuxDebug.loadSeed`), then `loadTick`
// (loadDebug.ts) three ways: the transcript scrolled alone, the transcript scrolled while a command
// runs and another chat in the list changes, and Session Info's own body scrolled. Nothing the panel
// shows changes with a scroll, so a scroll alone draws none of it (0 or 1 render of each part in the
// run), and under a running command its sections draw once per real change, never per frame.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-scroll-renders.test.ts", async () => {
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

  /// The seeded chat with Session Info open beside it.
  async function openPane(height: number): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 1400, height } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    // Session Info on (Debug Settings `agent.sessionInfo`), as the header state carries it.
    await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
    const toggle = page.locator("button.acpmux-session-info-toggle").first();
    await toggle.waitFor({ timeout: 10_000 });
    if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
    await page.waitForFunction(
      () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
    );
    // The enter slide ends before the count starts.
    await page.waitForFunction(
      () => document.querySelector("aside.acpmux-session-info")!.getAnimations({ subtree: true }).length === 0,
    );
    return page;
  }

  /// What a running turn really changes in Session Info over the run, each drawn once.
  const STRUCTURAL = 6;

  const run = async (page: Page, options: Record<string, unknown>) => {
    const report = (await page.evaluate((o) => (window as any).cmuxAcpmuxDebug.loadTick(o), options)) as Record<
      string,
      any
    >;
    console.log(`SESSION-INFO-SCROLL-RENDERS ${JSON.stringify({ options, ...report, busiest: undefined })}`);
    expect(report.error).toBeUndefined();
    expect(report.session_info).toBeDefined();
    return report;
  };

  test("scrolling the transcript draws Session Info no more than once", async () => {
    const page = await openPane(820);
    // fixed-wait: the run is a timed scroll; its length is what is measured over.
    const report = await run(page, { seconds: 4, tick_ms: 0 });
    await page.close();
    // The scroll went through the history.
    expect(report.history_mounts).toBeGreaterThan(30);
    expect(report.session_info.presence, "Session Info presence renders").toBeLessThanOrEqual(1);
    expect(report.session_info.panel, "Session Info panel renders").toBeLessThanOrEqual(1);
    expect(report.session_info.sections, "Session Info sections renders").toBeLessThanOrEqual(1);
  });

  test("scrolling the transcript while a command runs draws Session Info's sections once per change", async () => {
    const page = await openPane(820);
    // fixed-wait: the run is a timed scroll under a command's timed output; its length is measured over.
    const report = await run(page, { seconds: 6, tick_ms: 100, sidebar_ms: 250 });
    await page.close();
    expect(report.ticks).toBeGreaterThan(30);
    expect(report.sidebar).toBeGreaterThan(10);
    // The turn's start and end, the call's own row, an older page landing: a handful, never one per
    // tick, per change to another chat or per scrolled frame.
    expect(report.session_info.panel, "Session Info panel renders").toBeLessThanOrEqual(STRUCTURAL);
    expect(report.session_info.sections, "Session Info sections renders").toBeLessThanOrEqual(STRUCTURAL);
  });

  test("scrolling Session Info itself draws it no more than once", async () => {
    const page = await openPane(520);
    // fixed-wait: the run is a timed scroll; its length is what is measured over.
    const report = await run(page, { seconds: 4, tick_ms: 0, scroll_target: "session-info", scroll_speed: 600 });
    await page.close();
    expect(report.scrolled_px).toBeGreaterThan(50);
    expect(report.session_info.presence, "Session Info presence renders").toBeLessThanOrEqual(1);
    expect(report.session_info.panel, "Session Info panel renders").toBeLessThanOrEqual(1);
    expect(report.session_info.sections, "Session Info sections renders").toBeLessThanOrEqual(1);
    // The scroll mark (scrollers.ts) is set once for the scroll, not on every step of it.
    expect(report.session_info.scroll_marks, "scroll marks set on Session Info's body").toBeLessThanOrEqual(1);
  });
});
