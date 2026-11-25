// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// Scrolling the transcript while a tool call runs and the chat list changes redraws no history row
// (Leo, 2026-11-06: "Still seeing the flicker re-render. Sometimes when I scroll up, at the same time
// that you have, like, I don't know, maybe an ongoing tool or something, like, or that something
// changes in the sidebar").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a chat of 300
// heavy turns seeded through attach (`cmuxAcpmuxDebug.loadSeed`), then `loadTick`: one command runs
// for six seconds, its output updating every 100 ms, another chat in the list changes every 250 ms,
// and the reader scrolls up twelve viewports and back the whole time (loading older pages as it
// goes). A history row's content never changes over the run, so it draws when it mounts (scrolled
// into the window) and then not again: its frame may move (a row above measured, an older page
// landed) or take the tab stop, and that redraws the frame only, never what is in it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-scroll-tick-renders.test.ts", async () => {
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

  /// The turn's own structural changes may redraw a history row's content once each (the last
  /// footer stops being the chat's last when the new turn starts): a handful in the run, never one
  /// per tick or per scrolled frame.
  const STRUCTURAL = 6;

  test("scrolling while a command runs and the chat list changes redraws no history row", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 6, tick_ms: 100, sidebar_ms: 250 }),
    )) as Record<string, any>;
    await page.close();
    console.log(`SCROLL-TICK-RENDERS ${JSON.stringify(run)}`);
    expect(run.error).toBeUndefined();
    expect(run.ticks).toBeGreaterThan(30);
    expect(run.sidebar).toBeGreaterThan(10);
    // The scroll went through the history: rows came into the window.
    expect(run.history_mounts).toBeGreaterThan(50);
    // The frames did move under the scroll, so the bound below is not met by an idle run.
    expect(run.frame_rerenders).toBeGreaterThan(50);
    expect(run.content_rerenders, "history rows' content drawn again past its mount").toBeLessThanOrEqual(STRUCTURAL);
  });
});
