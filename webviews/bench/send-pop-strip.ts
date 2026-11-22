// l10n-allow-file: bench fixture prompts, not shipped UI.
// A frame-by-frame strip of a sent prompt's pop (conversation.css SEND-POP), for the PR beside Claude's: the
// production pane on the mock daemon sends a prompt (and, with --attachment, a pasted screenshot), then holds the
// pop's animation at each 30 ms of its 450 ms and screenshots the transcript. Exact times, not a screen recording.
//   bun bench/send-pop-strip.ts OUT_DIR [--engine webkit|chromium] [--attachment] [--pop product|claude-fade|spring]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit } from "./browsers";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const OUT = argv[0]!;
const ENGINE = flag("--engine") ?? "webkit";
const ATTACHMENT = argv.includes("--attachment");
const POP = flag("--pop") ?? "product";
const field = '.acpmux-composer-prompt [contenteditable="true"]';
const webviews = path.resolve(import.meta.dir, "..");
fs.mkdirSync(OUT, { recursive: true });

const { build, preview } = await import("vite");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-pop-strip-"));
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
const browser = await (ENGINE === "webkit" ? webkit : chromium).launch({ headless: true });
try {
  const page = await browser.newPage({
    viewport: { width: 900, height: 640 },
    deviceScaleFactor: 2,
    colorScheme: "dark",
  });
  await page.goto(`${pane.resolvedUrls!.local[0]!.replace(/\/$/, "")}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  await page.evaluate(() =>
    (window as unknown as { cmuxAcpmuxDebug: { loadSeed(turns: number): Promise<unknown> } }).cmuxAcpmuxDebug.loadSeed(
      4,
    ),
  );
  await page.locator(field).waitFor({ timeout: 60_000 });
  if (POP !== "product") await page.evaluate((pop) => document.documentElement.setAttribute("data-send-pop", pop), POP);
  await page.locator(field).click();
  if (ATTACHMENT) {
    await page.evaluate(async (selector) => {
      const canvas = document.createElement("canvas");
      canvas.width = 1600;
      canvas.height = 1000;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a7bd5";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#f2f4f8";
      context.fillRect(100, 100, 1400, 140);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      document
        .querySelector(selector)!
        .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, field);
    await page.waitForTimeout(600);
  }
  await page.keyboard.type("and the send behaviour too... it does a little pop and settle, so much nicer feeling");
  await page.waitForTimeout(300);
  // Hold every pop the moment it starts, before its first frame paints.
  await page.evaluate(() => {
    const w = window as unknown as { __held: Animation[] };
    w.__held = [];
    const watch = () => {
      for (const animation of document.getAnimations())
        if ((animation as CSSAnimation).animationName?.startsWith("cv-send-pop") && !w.__held.includes(animation)) {
          animation.pause();
          w.__held.push(animation);
        }
      if (w.__held.length === 0) requestAnimationFrame(watch);
    };
    new MutationObserver(watch).observe(document.body, { subtree: true, childList: true, attributes: true });
    requestAnimationFrame(watch);
  });
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => (window as unknown as { __held: Animation[] }).__held.length > 0, null, {
    timeout: 10_000,
  });
  await page.waitForTimeout(300);
  const row = page.locator(".acpmux-row.acpmux-user", { hasText: "little pop and settle" }).last();
  for (let ms = 0; ms <= 450; ms += 30) {
    // Paused at each time: the entrance clock's first-frame release (entranceClock.ts) plays a paused pop again.
    await page.evaluate((at) => {
      for (const animation of (window as unknown as { __held: Animation[] }).__held) {
        animation.pause();
        animation.currentTime = at;
      }
    }, ms);
    await page.waitForTimeout(60);
    // The row's own box, read at each frame: the view follows the mock's turn as it streams.
    const box = await row.boundingBox();
    const clip = box
      ? { x: 0, y: Math.max(0, box.y - 16), width: 900, height: Math.min(box.height + 32, 640) }
      : undefined;
    await page.screenshot({ path: path.join(OUT, `pop-${String(ms).padStart(3, "0")}.png`), clip });
  }
  console.log(`send-pop-strip: wrote ${OUT} (${ENGINE}${ATTACHMENT ? ", attachment" : ""}, pop ${POP})`);
} finally {
  await browser.close();
  await pane.close();
  fs.rmSync(out, { recursive: true, force: true });
}
