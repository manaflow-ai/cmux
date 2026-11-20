// l10n-allow-file: benchmark output, not shipped UI.
// Typing in one chat while it and other chats of the same renderer stream (the Mac's agent chats share one renderer,
// CEFSwitches processPerSitePageSchemes). Measures the composer's to_listener (keydown event time to the page's first
// keydown listener: the wait for the renderer main thread) and breaks the renderer main thread's tasks during the
// typing window into sources from a Chromium trace.
//   bun bench/shared-renderer-typing.bench.ts [--chats 2] [--keys 60] [--gap 80] [--cpu 4] [--rows 500] [--trace out.json]
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const CHATS = Number(flag("--chats") ?? 2);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 80);
const CPU = Number(flag("--cpu") ?? 4);
const ROWS = Number(flag("--rows") ?? 500);
const TRACE_OUT = flag("--trace");
/// With --keep DIR: a copy of the built pane, so a trace's line numbers can be read against it.
const KEEP = flag("--keep");
const DIR = flag("--dir") ?? path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";

const releases: (() => unknown)[] = [];
const port = await servePane(
  DIR,
  {
    unminified: Boolean(TRACE_OUT),
    built: KEEP ? (out: string) => fs.cpSync(out, KEEP, { recursive: true }) : undefined,
  },
  releases,
);
const browser = await chromium.launch({ headless: true, args: ["--process-per-site"] });
try {
  const context = await browser.newContext({ viewport: { width: 1100, height: 820 } });
  const pages: Page[] = [];
  for (let i = 0; i < CHATS; i += 1) {
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(
      (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
      Math.round(ROWS / 3),
    )) as Record<string, any>;
    if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
    await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
    pages.push(page);
  }
  const typed = pages[0]!;
  await typed.bringToFront();
  const cdp = await context.newCDPSession(typed);
  if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
  await typed.locator(PROMPT).first().click();
  for (const key of "warm") await typed.keyboard.press(key);
  for (let i = 0; i < 4; i += 1) await typed.keyboard.press("Backspace");
  await typed.waitForTimeout(500);
  const seconds = (KEYS * (GAP_MS + 30)) / 1000 + 2;
  const streams = pages.map((page) =>
    page.evaluate(
      (s) => (window as any).cmuxAcpmuxDebug.loadRun({ seconds: s, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
      seconds,
    ),
  );
  await typed.waitForTimeout(400);
  await typed.evaluate(() => (window as any).cmuxAcpmuxDebug.resetTyping());
  if (TRACE_OUT)
    await browser.startTracing(typed, {
      categories: [
        "devtools.timeline",
        "disabled-by-default-devtools.timeline",
        "toplevel",
        "v8.execute",
        "blink.user_timing",
        "input",
        "ipc",
        "mojom",
        "scheduler",
        "renderer.scheduler",
        "v8",
      ],
    });
  for (let i = 0; i < KEYS; i += 1) {
    await typed.keyboard.press("abcdefghijklmnopqrstuvwxyz"[i % 26]!);
    await typed.waitForTimeout(GAP_MS);
  }
  if (TRACE_OUT) fs.writeFileSync(TRACE_OUT, await browser.stopTracing());
  await typed.waitForTimeout(300);
  const typing = (await typed.evaluate(() => (window as any).cmuxAcpmuxDebug.typingStats())) as Record<string, any>;
  await Promise.all(streams);
  const pids = await Promise.all(
    pages.map((page) => page.evaluate(() => (performance as any).memory?.usedJSHeapSize ?? 0)),
  );
  console.log(
    `SHARED-TYPING ${JSON.stringify({ chats: CHATS, cpu: CPU, rows: ROWS, keys: KEYS, heap: pids, ...typing })}`,
  );
} finally {
  await browser.close();
  for (const release of releases) await release();
}
