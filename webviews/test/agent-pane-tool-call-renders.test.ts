// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A tool call in a streaming turn draws neither the composer nor Session Info again, unless something
// they show changed (Leo, 2026-11-07: "I feel like the composer and the session info thing, like
// that's still doing these kind of flicker re-renders when you are streaming in text."). A tool call is
// a transcript change: its row is new, so the pane draws it, but the composer shows no tool call, and
// Session Info shows one only where it changes what a section lists (a source the call read).
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with Session Info
// open over the chat, a seeded chat, then one turn streamed at full speed with a tool call every 8
// text chunks (`loadRun` `tool_every`). Renders are counted per component (`acpmuxPerf.renders`);
// what Session Info shows is read after each change to its DOM (its text), so each of its draws can be set against a
// real change.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tool-call-renders.test.ts", async () => {
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

  /// What a turn changes besides its tool calls, each drawn once: its prompt, its start (Stop), its
  /// end, the chat's status in and out.
  const STRUCTURAL = 4;

  test("a tool call draws neither the composer nor Session Info, past what they show", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 820 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(120))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }));
    const toggle = page.locator("button.acpmux-session-info-toggle").first();
    await toggle.waitFor({ timeout: 10_000 });
    if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
    await page.waitForFunction(
      () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
    );
    await page.waitForFunction(
      () => document.querySelector("aside.acpmux-session-info")!.getAnimations({ subtree: true }).length === 0,
    );
    // Session Info's text, read after each batch of DOM changes in it: each new text is one change it shows.
    await page.evaluate(() => {
      const scope = window as any;
      const panel = document.querySelector("aside.acpmux-session-info")!;
      scope.__panelTexts = 0;
      let last = panel.textContent;
      scope.__panelWatch = new MutationObserver(() => {
        const now = panel.textContent;
        if (now !== last) scope.__panelTexts += 1;
        last = now;
      });
      scope.__panelWatch.observe(panel, { subtree: true, childList: true, characterData: true });
    });
    const run = (await page.evaluate(() =>
      (window as any).cmuxAcpmuxDebug.loadRun({
        seconds: 4,
        chunk_chars: 24,
        chunk_ms: 12,
        tool_every: 8,
        scroll_speed: 0,
      }),
    )) as Record<string, any>;
    const panelChanges = (await page.evaluate(() => {
      (window as any).__panelWatch.disconnect();
      return (window as any).__panelTexts;
    })) as number;
    await page.close();
    const renders = (run.renders ?? {}) as Record<string, number>;
    const report = {
      deltas: run.deltas,
      tools: run.tools,
      pane: renders.pane ?? 0,
      composer: renders.composer ?? 0,
      sessionInfoPanel: renders["session-info:panel"] ?? 0,
      sessionInfoSections: renders["session-info:sections"] ?? 0,
      sessionInfoChanges: panelChanges,
    };
    console.log(`TOOL-CALL-RENDERS ${JSON.stringify(report)}`);
    // The turn made tool calls, and the pane drew their rows.
    expect(report.tools).toBeGreaterThan(10);
    expect(report.pane).toBeGreaterThan(report.tools);
    expect(report.composer, "composer renders over the turn's tool calls").toBeLessThanOrEqual(STRUCTURAL);
    // Session Info draws for what it shows changing (a source count), never once per tool call.
    expect(report.sessionInfoSections, "Session Info sections renders").toBeLessThanOrEqual(
      report.sessionInfoChanges + STRUCTURAL,
    );
    expect(report.sessionInfoPanel, "Session Info panel renders").toBeLessThanOrEqual(
      report.sessionInfoChanges + STRUCTURAL,
    );
  });
});
