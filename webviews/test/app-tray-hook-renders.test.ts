// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// The pane's tray moved out of App.tsx into subagents/usePaneTray.ts (its lines, held by their key
// while a turn streams; what ended and lingers in the hat; the card's motion), which the React Compiler
// compiles where it skips App. The tray's life in the real pane is unchanged, and the pane draws no
// more often for it than the base did.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a chat seeded
// through attach (`cmuxAcpmuxDebug.loadSeed`), then `loadTick`: the turn sends two shells to the
// background, which the hat shows with their time ticking, and one command runs with its output
// updating every 100 ms. No scroll and no other chat changing, so each render is the turn's own. The
// hat shows both shells, renders at most once in the still window (its lines are held by their key,
// not redrawn per update), and the pane and the hat render over the run no more than on the base
// (lane VM, 2026-11-18, both engines: 5 pane renders and 1 hat render over 49 updates, the same
// after the move). Real Chromium and WebKit; CI fails the file when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("app-tray-hook-renders.test.ts", async () => {
  setDefaultTimeout(280_000);
  const HAT = "section.acpmux-running-tray:not(.acpmux-running-tray--ghost)";
  const SHELLS = 2;
  /// The pane's and the hat's renders over the run on the base, before the move (lane VM, both engines).
  const BASE_PANE_RENDERS = 5;
  const BASE_TRAY_RENDERS = 1;
  /// Renders of the hat inside the still window an event other than an update may cause.
  const EVENTS = 1;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`app-tray-hook-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("background shells show in the hat, and the pane draws no more per update than on the base", async () => {
        const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
        await page.goto(`${base}/?mock`);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
        await page.locator(COMPOSER_EDITOR).waitFor();
        const seeded = (await page.evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadSeed(40, { light: true }),
        )) as Record<string, unknown>;
        expect(seeded.error).toBeUndefined();
        // The run goes on in the page while the hat is read: it shows while the turn runs.
        await page.evaluate(
          ({ shells, hat }) => {
            (window as any).__trayRun = (window as any).cmuxAcpmuxDebug.loadTick({
              seconds: 5,
              tick_ms: 100,
              sidebar_ms: 0,
              scroll_speed: 0,
              background_commands: shells,
              still: { hat },
              still_settle_ms: 1500,
            });
          },
          { shells: SHELLS, hat: HAT },
        );
        await page.locator(HAT).waitFor();
        const hat = await page.locator(HAT).innerText();
        const run = (await page.evaluate(() => (window as any).__trayRun)) as Record<string, any>;
        await page.close();
        const renders = (run.renders ?? {}) as Record<string, number>;
        const updates = Math.max(1, Number(run.ticks ?? 0));
        const still = run.still as Record<string, any> | undefined;
        const report = {
          engine: name,
          tool_updates: run.ticks,
          pane: renders.pane ?? 0,
          pane_per_update: Math.round(((renders.pane ?? 0) / updates) * 1000) / 1000,
          tray: renders.tray ?? 0,
          still_pane: still?.renders?.pane ?? 0,
          still_tray: still?.renders?.tray ?? 0,
          still_s: still?.window_s,
          hat,
        };
        console.log(`APP-TRAY-HOOK-RENDERS ${JSON.stringify(report)}`);
        expect(run.error).toBeUndefined();
        expect(still?.error).toBeUndefined();
        expect(run.ticks, "the command's output updated").toBeGreaterThan(20);
        expect(still?.parts?.hat?.missing_frames, "frames without the hat in the still window").toBe(0);
        expect(still?.parts?.hat?.nodes, "the hat drawn as more than one node (a remount)").toBe(1);
        expect(hat, "the hat shows the background shells").toContain("bun run dev");
        expect(report.still_tray, "hat renders in the still window").toBeLessThanOrEqual(EVENTS);
        expect(report.pane, "pane renders over the run").toBeLessThanOrEqual(BASE_PANE_RENDERS);
        expect(report.tray, "hat renders over the run").toBeLessThanOrEqual(BASE_TRAY_RENDERS);
      });
    });
  }
});
