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
import { chromium, type Browser, type Page } from "playwright";
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

  // The reader's own pointer over the transcript while the hat ticks: hovering the prompt rail's ticks
  // and wheeling over the rail and the transcript (Leo, 2026-11-07: "when I'm hovering through and
  // scrolling through the scroll rail, it seems like the composer still flickers"), and resting on a
  // sent screenshot while the transcript wheels under it (Leo, 2026-11-08: "when I was hovering over a
  // preview of a screenshot or whatever and then scrolling, I was getting these rapid flickers,
  // re-renders of the composer area"). Neither changes anything the composer or the hat shows: not one
  // render of either, not one DOM change in either.
  type Pointer = (page: Page, until: () => boolean) => Promise<{ hovers: number; wheels: number }>;
  const box = async (page: Page, selector: string) => {
    const found = await page.locator(selector).first().boundingBox();
    if (!found) throw new Error(`no ${selector}`);
    return found;
  };
  /// Sweeps the pointer down and up the rail's ticks (each a hover, its card shown), wheels over the
  /// rail, then over the transcript, round after round.
  const railPointer: Pointer = async (page, until) => {
    let hovers = 0;
    let wheels = 0;
    while (!until()) {
      const rail = await box(page, ".acpmux-minimap__rail");
      const x = rail.x + rail.width / 2;
      for (let step = 0; step <= 24 && !until(); step += 1) {
        const at = step <= 12 ? step / 12 : (24 - step) / 12;
        await page.mouse.move(x, rail.y + 2 + at * (rail.height - 4));
        hovers += 1;
        await page.waitForTimeout(16);
      }
      for (let turn = 0; turn < 6 && !until(); turn += 1) {
        await page.mouse.wheel(0, turn < 3 ? -240 : 240);
        wheels += 1;
        await page.waitForTimeout(40);
      }
      const transcript = await box(page, ".acpmux-scroll");
      await page.mouse.move(transcript.x + transcript.width / 2, transcript.y + transcript.height / 2);
      for (let turn = 0; turn < 6 && !until(); turn += 1) {
        await page.mouse.wheel(0, turn < 3 ? -320 : 320);
        wheels += 1;
        await page.waitForTimeout(40);
      }
    }
    return { hovers, wheels };
  };
  /// Rests the pointer on a sent screenshot in view, then wheels the transcript under it a little at a
  /// time, up and back, so the pointer enters and leaves rows and their screenshots as they pass.
  const screenshotPointer: Pointer = async (page, until) => {
    let hovers = 0;
    let wheels = 0;
    while (!until()) {
      const shot = await page.evaluate(() => {
        const scroller = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
        for (const image of document.querySelectorAll(".acpmux-scroll .cv-user__images img")) {
          const rect = image.getBoundingClientRect();
          if (rect.width > 0 && rect.top > scroller.top + 20 && rect.bottom < scroller.bottom - 20)
            return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        }
        return undefined;
      });
      if (shot) {
        await page.mouse.move(shot.x, shot.y, { steps: 4 });
        hovers += 1;
        await page.waitForTimeout(120);
      }
      for (let turn = 0; turn < 16 && !until(); turn += 1) {
        await page.mouse.wheel(0, turn < 8 ? -90 : 90);
        wheels += 1;
        await page.waitForTimeout(30);
      }
      if (!shot) await page.mouse.wheel(0, -600);
    }
    return { hovers, wheels };
  };

  for (const [name, pointer, imagesEvery] of [
    ["hovering and wheeling the prompt rail", railPointer, 0],
    ["resting on a sent screenshot while the transcript wheels", screenshotPointer, 2],
  ] as const)
    test(`${name} while the hat ticks leaves the composer and the hat still`, async () => {
      const page = await browser!.newPage({ viewport: { width: 1100, height: 760 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/?mock`);
      await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
      const seeded = (await page.evaluate(
        (every) => (window as any).cmuxAcpmuxDebug.loadSeed(120, { images_every: every }),
        imagesEvery,
      )) as Record<string, any>;
      expect(seeded.error).toBeUndefined();
      await page.locator(".acpmux-minimap__rail").first().waitFor({ timeout: 30_000 });
      // Start a few viewports up, where sent screenshots (or the rail's older prompts) are in view.
      const transcript = await box(page, ".acpmux-scroll");
      await page.mouse.move(transcript.x + transcript.width / 2, transcript.y + transcript.height / 2);
      for (let turn = 0; turn < 6; turn += 1) await page.mouse.wheel(0, -500);
      await page.waitForTimeout(300);
      let done = false;
      const running = page
        .evaluate(() =>
          (window as any).cmuxAcpmuxDebug.loadTick({
            seconds: 8,
            tick_ms: 100,
            sidebar_ms: 250,
            background_commands: 1,
            scroll_target: "pointer",
            still: { composer: "form.acpmux-composer", hat: "section.acpmux-running-tray" },
            still_settle_ms: 1500,
          }),
        )
        .finally(() => (done = true));
      const moved = await pointer(page, () => done);
      const run = (await running) as Record<string, any>;
      await page.close();
      const still = run.still as Record<string, any>;
      const report = {
        case: name,
        ...moved,
        window_s: still?.window_s,
        clock_ticks: still?.clock_ticks,
        composer_renders: still?.renders?.composer ?? 0,
        hat_renders: still?.renders?.tray ?? 0,
        pane_renders: still?.renders?.pane ?? 0,
        renders: still?.renders,
        parts: still?.parts,
      };
      console.log(`COMPOSER-HAT-POINTER ${JSON.stringify(report)}`);
      expect(run.error).toBeUndefined();
      expect(still?.error).toBeUndefined();
      expect(still.clock_ticks).toBeGreaterThanOrEqual(4);
      expect(moved.hovers).toBeGreaterThan(5);
      expect(moved.wheels).toBeGreaterThan(20);
      for (const part of ["composer", "hat"]) {
        expect(still.parts[part].missing_frames, `${part} frames without it`).toBe(0);
        expect(still.parts[part].nodes, `${part} drawn as more than one node (a remount)`).toBe(1);
        expect(still.parts[part].moved_px, `${part} moved or resized (px)`).toBeLessThanOrEqual(0.5);
        expect(still.parts[part].structure_mutations, `${part} nodes added, removed or re-attributed`).toBe(0);
      }
      expect(report.composer_renders, "composer renders while the pointer hovers and wheels").toBe(0);
      expect(report.hat_renders, "hat renders while the pointer hovers and wheels").toBe(0);
    });
});
