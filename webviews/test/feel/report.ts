// The feel report: one short markdown table and its JSON per component, beside the recording of the
// simulated cursor (a webm per scenario), in $CMUX_FEEL_OUT/<component> (default
// $TMPDIR/cmux-feel/<component>). The recording draws the cursor as a dot (headless Chromium paints
// none): pointer-events none, fixed, so it changes no layout and no hit test.
import { mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, BrowserContext, Page } from "playwright";
import type { Verdict } from "./verdicts";

export function feelDir(component: string): string {
  const dir = path.join(process.env.CMUX_FEEL_OUT ?? path.join(os.tmpdir(), "cmux-feel"), component);
  mkdirSync(dir, { recursive: true });
  return dir;
}

export type ScenarioResult = {
  scenario: string;
  verdicts: Verdict[];
  numbers: Record<string, unknown>;
  video?: string;
  /** Known to fail on this base, and who is fixing it (stage.ts `known`). */
  known?: string;
};

/** Writes report.md and report.json for `component`; returns the markdown. */
export function writeReport(component: string, results: ScenarioResult[]): string {
  const dir = feelDir(component);
  const failed = results.flatMap((result) => result.verdicts.filter((verdict) => !verdict.pass));
  const lines = [
    `# Feel: ${component}: ${failed.length === 0 ? "PASS" : `FAIL (${failed.length})`}`,
    "",
    "| scenario | check | measured | limit | |",
    "|---|---|---|---|---|",
    ...results.flatMap((result) =>
      result.verdicts.map(
        (verdict) =>
          `| ${result.scenario} | ${verdict.check} | ${verdict.measured} | ${verdict.limit} | ${verdict.pass ? "ok" : "**FAIL**"} |`,
      ),
    ),
    "",
    ...results.filter((result) => result.known).map((result) => `- ${result.scenario}: known red, ${result.known}`),
    "",
    ...results.filter((result) => result.video).map((result) => `- ${result.scenario}: ${result.video}`),
  ];
  const markdown = `${lines.join("\n")}\n`;
  writeFileSync(path.join(dir, "report.md"), markdown);
  writeFileSync(path.join(dir, "report.json"), `${JSON.stringify(results, null, 2)}\n`);
  return markdown;
}

/** Whether to record video (CMUX_FEEL_RECORD=0 turns it off). */
export const recording = () => process.env.CMUX_FEEL_RECORD !== "0";

/** A context that records its pages into `dir` when recording is on. */
export async function feelContext(
  browser: Browser,
  dir: string,
  viewport: { width: number; height: number },
): Promise<BrowserContext> {
  const context = await browser.newContext({
    viewport,
    ...(recording() ? { recordVideo: { dir, size: viewport } } : {}),
  });
  if (recording()) await context.addInitScript(drawCursor);
  return context;
}

/** The page side of the recording's cursor dot. */
function drawCursor() {
  const dot = document.createElement("div");
  dot.setAttribute("data-feel-cursor", "");
  dot.style.cssText =
    "position:fixed;left:0;top:0;width:12px;height:12px;margin:-6px 0 0 -6px;border-radius:50%;" +
    "background:rgba(255,60,60,.55);border:1px solid #fff;pointer-events:none;z-index:2147483647;" +
    "transition:none;contain:strict";
  const place = (event: PointerEvent) => {
    dot.style.transform = `translate(${event.clientX}px, ${event.clientY}px) scale(${event.buttons ? 0.7 : 1})`;
    if (!dot.isConnected) document.documentElement.append(dot);
  };
  for (const kind of ["pointermove", "pointerdown", "pointerup"])
    addEventListener(kind, place as EventListener, { capture: true, passive: true });
}

/** Closes `page` and returns where its recording went (if any), renamed for `scenario`. */
export async function saveRecording(page: Page, dir: string, scenario: string): Promise<string | undefined> {
  const video = page.video();
  await page.close();
  if (!video) return undefined;
  const target = path.join(dir, `${scenario.replaceAll(/[^a-z0-9]+/gi, "-")}.webm`);
  try {
    await video.saveAs(target);
    await video.delete();
    return target;
  } catch {
    return undefined;
  }
}
