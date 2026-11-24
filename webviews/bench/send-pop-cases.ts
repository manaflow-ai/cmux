// l10n-allow-file: bench fixture prompts, not shipped UI.
// Every shape a sent prompt takes, through the pop (conversation.css SEND-POP), judged by bench/send-pop-probe.js
// (Leo 2026-11-22: "oh you better probably also watch that attachments and such are good too when the pop is
// there"): one picture, several, a file chip, a big paste (its Pasted text chip), a picture and text, a long
// multi-line prompt, and a send while the reply before it still streams. The production pane on the in-page mock;
// a tagged app runs the same probe (scripts/measure/send-pop-films.py).
//   bun bench/send-pop-cases.ts [--engine chromium|webkit] [--turns N] [--cases a,b] [--json FILE]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Page } from "playwright";
import { chromium, webkit } from "./browsers";
import { SEND_POP_SHAPES } from "./send-pop-shapes";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const ENGINE = flag("--engine") ?? "chromium";
const TURNS = Number(flag("--turns") ?? 4);
const JSON_OUT = flag("--json");
export const CASES = SEND_POP_SHAPES;
const WANTED = (flag("--cases") ?? Object.keys(CASES).join(",")).split(",");
const field = '.acpmux-composer-prompt [contenteditable="true"]';
const webviews = path.resolve(import.meta.dir, "..");
const probe = fs.readFileSync(path.join(import.meta.dir, "send-pop-probe.js"), "utf8");

const { build, preview } = await import("vite");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-pop-cases-"));
await build({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out, emptyOutDir: true },
  logLevel: "error",
});
const pane = await preview({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out },
  preview: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});

async function idle(page: Page) {
  await page
    .getByRole("button", { name: "Stop" })
    .waitFor({ state: "detached", timeout: 30_000 })
    .catch(() => undefined);
  await page.waitForTimeout(300);
}

async function send(page: Page, marker: string, shape: (typeof CASES)[string]) {
  await page.locator(field).click();
  const attached = await page.evaluate((options) => (window as any).__sendPopProbe.attach(options), shape);
  // Focus, not a click: a click lands on the composer's picture and opens its viewer.
  await page.locator(field).focus();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type(` ${marker}`);
  await page.waitForTimeout(200);
  await page.evaluate((m) => (window as any).__sendPopProbe.arm(m), marker);
  await page.keyboard.press("Enter");
  // A prompt sent while a reply streams waits in the queue and joins the transcript when that turn ends.
  await page
    .locator(".acpmux-row.acpmux-user", { hasText: marker })
    .first()
    .waitFor({ timeout: 30_000 })
    .catch(() => undefined);
  await page.waitForTimeout(1600);
  const judged = await page.evaluate(() => (window as any).__sendPopProbe.result());
  if (process.env.SEND_POP_SHOTS)
    await page.screenshot({ path: path.join(process.env.SEND_POP_SHOTS, `${marker}.png`) });
  return { attached, ...judged };
}

const report: Record<string, unknown> = {};
const browser = await (ENGINE === "webkit" ? webkit : chromium).launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
  await page.goto(`${pane.resolvedUrls!.local[0]!.replace(/\/$/, "")}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  await page.evaluate((turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns), TURNS);
  await page.locator(field).waitFor({ timeout: 60_000 });
  // The pop is off unless switched on (agentPane.display.sendPop): the root gate the setting sets.
  await page.evaluate(() => document.documentElement.setAttribute("data-send-pop", "claude"));
  await page.evaluate(probe);
  // A warm-up send, not judged: the first send loads lazy chunks.
  await send(page, "warmup-0", {});
  await idle(page);
  for (const name of WANTED) {
    const shape = CASES[name]!;
    if (shape.streaming) {
      await page.locator(field).click();
      await page.keyboard.type(`${name}-first: tell me a long story`);
      await page.keyboard.press("Enter");
      // The first reply streams on: the second prompt goes while it does.
      await page
        .getByRole("button", { name: "Stop" })
        .waitFor({ timeout: 5_000 })
        .catch(() => undefined);
      await page.waitForTimeout(250);
      const streamingAtSend = await page
        .getByRole("button", { name: "Stop" })
        .isVisible()
        .catch(() => false);
      report[name] = { streamingAtSend, ...(await send(page, `${name}-second`, {})) };
    } else report[name] = await send(page, `${name}-${TURNS}`, shape);
    console.log(JSON.stringify({ engine: ENGINE, turns: TURNS, case: name, ...(report[name] as object) }));
    await idle(page);
  }
} finally {
  await browser.close();
  await pane.close();
  fs.rmSync(out, { recursive: true, force: true });
}
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify({ engine: ENGINE, turns: TURNS, report }, null, 2));
