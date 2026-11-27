// cmux-web-test-timeout: 300
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// Scrolling the transcript while a turn runs and the composer's hat ticks leaves the composer and the
// hat still: no React render of either per clock second or per tool update, no move or resize, and the
// same nodes from start to end (Leo, 2026-11-09: "im still sometimes seeing a flicker on the
// composer/composer hat when scrolling and things are running in background aka time is ticking + i
// assume you're either thinking or runnign tool calls").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), a chat of 300
// heavy turns seeded through attach (`cmuxAcpmuxDebug.loadSeed`), then `loadTick`: the turn sends one
// or two shells to the background (the hat shows them, its time ticking each second), one command
// runs for eight seconds with its output updating every 100 ms, another chat in the list changes every
// 250 ms, and the reader scrolls up twelve viewports and back the whole time. Its still window opens
// once the hat shows and the turn's start has settled, and closes before the turn ends: nothing the
// composer or the hat draws changes inside it but the ticking time's own text.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-scroll-tick-composer-hat-still.test.ts", async () => {
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

  /// Renders of the composer or the hat inside the still window that an event other than the clock
  /// may cause (a status change of the chat list racing the window's edge): one, never one per second.
  const EVENTS = 1;

  // One shell heads the hat alone (its name and time); two head it with their counts and the hat's time.
  for (const shells of [1, 2])
    test(`scrolling while the hat ticks (${shells} background shell${shells > 1 ? "s" : ""}) leaves the composer and the hat still`, async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      // The dev server's runtime budgets (devkit/perfBudgets.ts) collect instead of warning: the
      // composer and the hat are `still-surface`s, so a redraw of either per tick warns while anyone
      // edits the pane, not only here.
      await page.addInitScript(() => {
        (window as any).__cmuxPerfBudgets = { mode: "collect" };
      });
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/?mock`);
      await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
      const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<string, any>;
      expect(seeded.error).toBeUndefined();
      const run = (await page.evaluate(
        (count) =>
          (window as any).cmuxAcpmuxDebug.loadTick({
            seconds: 8,
            tick_ms: 100,
            sidebar_ms: 250,
            background_commands: count,
            still: { composer: "form.acpmux-composer", hat: "section.acpmux-running-tray" },
            still_settle_ms: 1500,
          }),
        shells,
      )) as Record<string, any>;
      const budgetViolations = (await page.evaluate(() =>
        ((window as any).__cmuxPerfBudgetsHandle?.violations ?? []).map((violation: any) => violation.message),
      )) as string[];
      await page.close();
      const still = run.still as Record<string, any>;
      const ticks = Math.max(1, still?.clock_ticks ?? 0);
      const report = {
        shells,
        window_s: still?.window_s,
        clock_ticks: still?.clock_ticks,
        tool_updates: run.ticks,
        composer_renders: still?.renders?.composer ?? 0,
        hat_renders: still?.renders?.tray ?? 0,
        composer_renders_per_tick: Math.round(((still?.renders?.composer ?? 0) / ticks) * 100) / 100,
        hat_renders_per_tick: Math.round(((still?.renders?.tray ?? 0) / ticks) * 100) / 100,
        pane_renders: still?.renders?.pane ?? 0,
        parts: still?.parts,
        budgets: budgetViolations,
      };
      console.log(`COMPOSER-HAT-TICK ${JSON.stringify(report)}`);
      expect(run.error).toBeUndefined();
      expect(still?.error).toBeUndefined();
      // The window saw the clock tick and the command's output update while the transcript scrolled.
      expect(still.clock_ticks).toBeGreaterThanOrEqual(4);
      expect(run.ticks).toBeGreaterThan(50);
      expect(run.history_mounts).toBeGreaterThan(50);
      for (const name of ["composer", "hat"]) {
        const part = still.parts[name];
        expect(part.missing_frames, `${name} frames without it`).toBe(0);
        expect(part.nodes, `${name} drawn as more than one node (a remount)`).toBe(1);
        expect(part.moved_px, `${name} moved or resized (px)`).toBeLessThanOrEqual(0.5);
      }
      expect(report.composer_renders, "composer renders in the still window").toBeLessThanOrEqual(EVENTS);
      expect(report.hat_renders, "hat renders in the still window").toBeLessThanOrEqual(EVENTS);
      // The hat's time ticks in its own text node: no node added, removed or re-attributed per second.
      expect(still.parts.hat.text_mutations, "the hat's time ticked").toBeGreaterThanOrEqual(3);
      expect(still.parts.hat.structure_mutations, "hat nodes added, removed or re-attributed").toBeLessThanOrEqual(
        EVENTS,
      );
      expect(
        budgetViolations.filter((message) => message.includes("still-surface")),
        "the dev budgets' still-surface warnings",
      ).toEqual([]);
      expect(
        still.parts.composer.structure_mutations,
        "composer nodes added, removed or re-attributed",
      ).toBeLessThanOrEqual(EVENTS);
    });
});
