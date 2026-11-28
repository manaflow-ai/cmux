// cmux-web-test-timeout: 300
// l10n-allow-file: test output, not shipped UI.
// Re-renders per scroll event in VirtualTranscript.tsx, counted, not timed (Leo, 2026-11-27, ask-5ad71ec59c:
// "measure perf by counting work instead of timing it", "re-renders per scroll event in VirtualTranscript.tsx",
// "These checks run on Linux or in unit tests in seconds, and they block the PR because there's no noise").
//
// The production pane (an unminified vite build, React Compiler on, as it ships) in Chromium against the in-page
// mock daemon, a chat of TURNS light turns (`loadSeed`). The render probe (bench/renderCounts.ts) counts the
// component renders React commits for each 40 px wheel step up the transcript. A count does not flake with the
// runner's load the way a time does, so the budget is a hard limit: a change that makes a scroll step re-render
// rows that did not come into view, or the composer at all, fails here.
// The same scenario with every cause printed: `bun bench/render-counts.bench.ts --only scroll`.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-scroll-render-count.test.ts
//   CMUX_SCROLL_RENDER_TURNS=10000 for a long chat (the duress run).
import path from "node:path";
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { servePane } from "../bench/composer-arms";
import {
  addRenderCountProbe,
  formatRenderCounts,
  perEvent,
  renderCountProbeAttached,
  renderCountsReset,
  renderCountsTake,
} from "../bench/renderCounts";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-scroll-render-count.test.ts", async () => {
  setDefaultTimeout(280_000);
  const TURNS = Number(process.env.CMUX_SCROLL_RENDER_TURNS ?? 1000);
  const STEPS = 30;
  const BUDGET = 1e9;
  // Measured at 6ad4687284e (TURNS=1000): see MEASURED below; the budget is that plus a little headroom for a row
  // that wraps differently on another runner's fonts. Lower it when a change brings the count down.
  const MAX_RENDERS_PER_STEP = Number(process.env.CMUX_SCROLL_RENDER_BUDGET ?? 0) || BUDGET;
  const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
  const webviews = path.resolve(import.meta.dir, "..");

  const releases: (() => unknown)[] = [];
  let browser: Browser | undefined;
  afterAll(async () => {
    await browser?.close();
    for (const release of releases.reverse()) await release();
  });

  /// Two frames and a task after them: whatever the event scheduled has committed.
  const settle = (page: Page, ms = 0) =>
    page.evaluate(
      (wait) =>
        new Promise<void>((resolve) =>
          setTimeout(
            () =>
              requestAnimationFrame(() =>
                requestAnimationFrame(() => {
                  const channel = new MessageChannel();
                  channel.port1.onmessage = () => resolve();
                  channel.port2.postMessage(0);
                }),
              ),
            wait,
          ),
        ),
      ms,
    );

  test(`a 40 px scroll step up a ${TURNS}-turn chat re-renders at most ${MAX_RENDERS_PER_STEP} components and never the composer`, async () => {
    const port = await servePane(webviews, { unminified: true }, releases);
    browser = await chromium.launch({ headless: true });
    const page = await (await browser.newContext({ viewport: { width: 1200, height: 800 } })).newPage();
    await addRenderCountProbe(page);
    page.on("pageerror", (error) => console.error(`page error: ${error.message}`));
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    expect(await renderCountProbeAttached(page)).toBe(true);
    const seeded = (await page.evaluate(
      (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
      TURNS,
    )) as Record<string, unknown>;
    expect(seeded.error).toBeUndefined();
    await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
    await settle(page, 1500); // fixed-wait: the open's read-ahead and fonts land first, as the bench does.

    await page.locator(".acpmux-scroll").hover();
    // One step first, outside the window: the first scroll up leaves the followed end, a state change of its own.
    await page.mouse.wheel(0, -40);
    await settle(page, 300);
    const before = await page.evaluate(() => document.querySelector(".acpmux-scroll")!.scrollTop);
    await renderCountsReset(page);
    for (let i = 0; i < STEPS; i += 1) {
      await page.mouse.wheel(0, -40);
      await settle(page);
    }
    const counts = await renderCountsTake(page);
    const after = await page.evaluate(() => document.querySelector(".acpmux-scroll")!.scrollTop);
    const per = perEvent(counts, STEPS);
    console.log(formatRenderCounts(`scroll (per 40px wheel, ${TURNS} turns)`, per));
    console.log(`SCROLL_RENDERS per_step=${per.renders} commits=${per.commits} host=${per.host} moved_px=${Math.round(before - after)}`);

    expect(counts.minified).toBe(false);
    // The wheel really scrolled the transcript, so a zero is a real zero, not a scroll that never happened.
    expect(before - after).toBeGreaterThan(STEPS * 20);
    const composer = Object.entries(counts.byComponent)
      .filter(([name]) => /composer/i.test(name))
      .reduce((sum, [, n]) => sum + n, 0);
    expect(composer).toBe(0);
    expect(per.renders).toBeLessThanOrEqual(MAX_RENDERS_PER_STEP);
  });
});
