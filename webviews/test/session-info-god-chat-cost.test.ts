// cmux-web-test-timeout: 300
// Session Info on a god chat costs what it costs on a small one (Leo, 2026-11-19: "dam this is slow as
// shit on the sesion info", on a chat with 28,408 background shells, 26 sources and 38 subagents: a
// section's chevron flipped at once and its list came 0.5-1.5 s later, and Background tasks went from
// "6 finished" to "28407 finished" after the panel drew). test/browser/session-info-god-chat.harness.tsx
// draws the whole panel with the registry as the page held it once Session Info opened (`whole`: every
// process) and as it holds it now (`window`: the running ones and the newest ended, the rest counted).
// Prints, per shape: the ms to parse the registry's reply, and the press-to-paint ms (p50 of 7 presses
// after a warm-up) for the Sources head, the Background tasks head and its "N finished" fold. The
// window's "N finished" is the whole history's count, the same as the whole list's.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("session-info-god-chat-cost.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/session-info-god-chat.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const N = 28_408;
  const PRESSES = 7;
  const HEADS = {
    sources: 'section[data-section="sources"] > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger',
    tasks: 'section[data-section="tasks"] > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger',
    finished: 'div[data-section="tasks"] > .acpmux-session-info-fold',
  };
  const p50 = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;

  /// Presses `selector` 1 + PRESSES times (the first a warm-up), each after the last settled, and
  /// answers the p50 of the timed presses.
  async function pressCost(page: Page, selector: string) {
    await page.waitForSelector(selector);
    const times: number[] = [];
    for (let press = 0; press <= PRESSES; press += 1) {
      const ms = await page.evaluate((target) => window.__press(target), selector);
      if (press > 0) times.push(ms);
      // Settled: the fold's transition ran out and two frames painted after it.
      await page.waitForFunction(() => document.getAnimations().every((a) => a.playState !== "running"));
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    }
    return p50(times);
  }

  async function measure(mode: "whole" | "window") {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 800 } });
    try {
      await page.goto(`http://127.0.0.1:${port}${PAGE}?mode=${mode}&n=${N}`);
      await page.waitForFunction(() => typeof window.__press === "function");
      const shape = await page.evaluate(() => window.__mode);
      const parses: number[] = [];
      for (let round = 0; round < 5; round += 1) parses.push(await page.evaluate(() => window.__parse()));
      const finishedText = (await page.locator('div[data-section="tasks"]').getAttribute("data-finished-count")) ?? "";
      const sources = await pressCost(page, HEADS.sources);
      const finished = await pressCost(page, HEADS.finished);
      const tasks = await pressCost(page, HEADS.tasks);
      return { ...shape, mode, parse: p50(parses), sources, tasks, finished, finishedText };
    } finally {
      await page.close();
    }
  }

  // GOD_CHAT_BASE=1 measures only the whole list, on a base tree that has no window (the PR's before).
  test.if(process.env.GOD_CHAT_BASE === "1")("before: the whole list on base", async () => {
    const whole = await measure("whole");
    console.log(
      `| base whole | ${whole.held} | ${whole.older} | ${whole.parse.toFixed(1)} | ${whole.sources.toFixed(1)} | ${whole.tasks.toFixed(1)} | ${whole.finished.toFixed(1)} | ${whole.finishedText.trim()} |`,
    );
  });

  test.if(process.env.GOD_CHAT_BASE !== "1")(
    "a god chat's Session Info toggles in a frame, its count the whole history's",
    async () => {
      const whole = await measure("whole");
      const windowed = await measure("window");
      const row = (r: typeof whole) =>
        `| ${r.mode} | ${r.held} | ${r.older} | ${r.parse.toFixed(1)} | ${r.sources.toFixed(1)} | ${r.tasks.toFixed(1)} | ${r.finished.toFixed(1)} | ${r.finishedText.trim()} |`;
      console.log(
        [
          "| registry | rows held | counted, not held | parse reply ms | Sources press-to-paint ms | Background tasks press-to-paint ms | finished fold press-to-paint ms | finished count |",
          "|---|---|---|---|---|---|---|---|",
          row(whole),
          row(windowed),
        ].join("\n"),
      );
      // The same count either way: the window's is the whole history's.
      expect(windowed.finishedText.trim()).toBe(whole.finishedText.trim());
      expect(windowed.finishedText).toBe(String(N - 1));
      expect(windowed.held + windowed.older).toBe(N);
      expect(windowed.held).toBeLessThan(1_000);
      // A section toggles within about a frame at this length.
      expect(windowed.sources).toBeLessThan(50);
      expect(windowed.finished).toBeLessThan(50);
    },
  );
});
