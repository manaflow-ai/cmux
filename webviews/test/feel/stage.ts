// A feel check's stage: the gallery dev server with one entry warmed, a recorded page per scenario
// opened on a variant with the probe installed, and the report written when the file ends. Each
// component's check (test/feel-*.test.ts) only says what to open, what to watch and how to judge it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { frames, installFeelProbe } from "./probe";
import { feelContext, feelDir, saveRecording, writeReport, type ScenarioResult } from "./report";
import { Verdicts } from "./verdicts";

export type StageOptions = {
  entry: string;
  variant: string;
  component: string;
  viewport: { width: number; height: number };
  /** Runs once the page is ready, before the scenario: the stage's own setup (a selector to wait for,
   *  a stored setting to clear). */
  prepare?: (page: Page) => Promise<void>;
  /** Scenarios known to fail on this base, each with who is fixing it: they run as `test.failing`, so
   *  the base stays green, the report still says FAIL, and the fix that makes one pass fails the run
   *  until its line here goes (bun: "marked as failing but it passed"). */
  known?: Record<string, string>;
};

/** Whether a headless Chromium launches here (a lane without browsers skips the check). */
export async function chromiumLaunches(): Promise<boolean> {
  try {
    await (await chromium.launch({ headless: true })).close();
    return true;
  } catch {
    return false;
  }
}

/** Sets up the server and browser for the test file (beforeAll/afterAll) and returns the scenario
 *  runner. Call it at the top of a `requireBrowserLane` body. */
export function feelStage(options: StageOptions) {
  const webviews = path.resolve(import.meta.dir, "../..");
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;
  let browser: Browser | undefined;
  const results: ScenarioResult[] = [];
  const dir = feelDir(options.component);

  beforeAll(async () => {
    const { createServer } = await import("vite");
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // A failed module fetch (a dev server still optimizing, a host's network blip) loads again.
    for (let attempt = 1; ; attempt++) {
      try {
        await warmGalleryFrame(vite, [options.entry], { browser, params: { variant: options.variant } });
        break;
      } catch (error) {
        if (attempt === 3 || !/Failed to fetch dynamically imported module/.test(String(error))) throw error;
      }
    }
  }, 120_000);
  afterAll(async () => {
    console.log(writeReport(options.component, results));
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant = options.variant): Promise<Page> => {
    const context = await feelContext(browser!, dir, options.viewport);
    const page = await context.newPage();
    await installFeelProbe(page);
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const url = `http://127.0.0.1:${port}${galleryFrame(options.entry, { variant })}`;
    for (let attempt = 1; ; attempt++) {
      await page.goto(url);
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        break;
      } catch (error) {
        if (attempt === 3 || !/context was destroyed|navigat|Timeout/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await options.prepare?.(page);
    await page.mouse.move(2, 2);
    // The entry's own entrance has run: nothing animates but what loops.
    await page.waitForFunction(() =>
      document.getAnimations().every((a) => a.playState !== "running" || a.effect?.getTiming().iterations === Infinity),
    );
    await frames(page, 4);
    return page;
  };

  /** Runs one scenario on a fresh recorded page and keeps its verdicts, numbers and recording. */
  const scenario = async (
    name: string,
    run: (page: Page, verdicts: Verdicts) => Promise<Record<string, unknown>>,
    variant?: string,
  ) => {
    const page = await open(variant);
    const verdicts = new Verdicts();
    let numbers: Record<string, unknown> = {};
    try {
      numbers = await run(page, verdicts);
    } finally {
      const video = await saveRecording(page, dir, name);
      await page.context().close();
      results.push({ scenario: name, verdicts: verdicts.list, numbers, video, known: options.known?.[name] });
    }
    return verdicts;
  };

  /** `test`, or `test.failing` for a scenario in `known`. */
  const testFor = (name: string) => (options.known?.[name] ? test.failing : test);

  return { open, scenario, testFor };
}

/** Fails the test with every failed verdict's check, measure and limit. */
export const expectPass = (verdicts: Verdicts) =>
  expect(verdicts.failed.map((v) => `${v.check}: ${v.measured} (limit ${v.limit})`)).toEqual([]);
