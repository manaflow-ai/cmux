// l10n-allow-file: bench fixture prompts, not shipped UI.
// A frame-by-frame strip of a sent prompt's pop (conversation.css SEND-POP), for the PR beside Claude's: the
// production pane on the mock daemon sends a prompt of one shape (bench/send-pop-shapes.ts: --case image, images,
// tall, decoding, file, image-text, ...; --attachment is image-text), then holds the pop's animation at each 30 ms
// of its 450 ms and screenshots the prompt. Exact times, not a screen recording. Each frame first brings the prompt's
// top 24 px below the transcript's top (the view follows the mock's streaming turn, and a frame cropped at the
// page's edge reads as a clipped picture), crops around the drawn (scaled) bubble, and writes strip.json: per frame,
// the bubble's box, how far a clipping box inside the row cuts an attachment (`rowClipPx`, must be 0) and how far the
// crop was cut by the page's edge (`cropCutPx`).
//   bun bench/send-pop-strip.ts OUT_DIR [--engine webkit|chromium] [--case NAME | --attachment]
//       [--pop product|claude-fade|spring]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit } from "./browsers";
import { SEND_POP_SHAPES } from "./send-pop-shapes";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const OUT = argv[0]!;
const ENGINE = flag("--engine") ?? "webkit";
const CASE = flag("--case") ?? (argv.includes("--attachment") ? "image-text" : "text");
const SHAPE = CASE === "text" ? {} : SEND_POP_SHAPES[CASE];
if (!SHAPE) throw new Error(`no case ${CASE}: ${Object.keys(SEND_POP_SHAPES).join(", ")}`);
const probe = fs.readFileSync(path.join(import.meta.dir, "send-pop-probe.js"), "utf8");
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
  // The product's pop is off unless switched on (agentPane.display.sendPop): "product" sets its root gate.
  await page.evaluate(
    (pop) => document.documentElement.setAttribute("data-send-pop", pop),
    POP === "product" ? "claude" : POP,
  );
  await page.evaluate(probe);
  await page.locator(field).click();
  await page.evaluate((shape) => (window as any).__sendPopProbe.attach(shape), SHAPE);
  // Focus, not a click: a click lands on the composer's picture and opens its viewer.
  await page.locator(field).focus();
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.type(" and the send behaviour too... it does a little pop and settle, so much nicer feeling");
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
  const frames: unknown[] = [];
  for (let ms = 0; ms <= 450; ms += 30) {
    // Paused at each time: the entrance clock's first-frame release (entranceClock.ts) plays a paused pop again.
    await page.evaluate((at) => {
      for (const animation of (window as unknown as { __held: Animation[] }).__held) {
        animation.pause();
        animation.currentTime = at;
      }
    }, ms);
    // Bring the prompt into view, let the frame settle, then read its box and shoot at once: a box read
    // before the wait raced the view, which the streaming turn moves.
    const measure = (scroll: boolean) =>
      row.evaluate((article, scroll) => {
        const scrollerOf = (el: Element) => {
          for (let node = el.parentElement; node; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (/(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight) return node;
          }
          return document.scrollingElement!;
        };
        const scroller = scrollerOf(article);
        // The prompt's top 24 px below the transcript's top, wherever the streaming turn moved the view.
        if (scroll)
          scroller.scrollTop += article.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 24;
        const presentation = article.querySelector(".acpmux-row__message-presentation") ?? article;
        const bubble = presentation.getBoundingClientRect();
        // Clipping inside the row (between an attachment and the scroller), as bench/send-pop-probe.js reads it.
        let rowClip = 0;
        for (const el of presentation.querySelectorAll(
          "img, .acpmux-attachment, .acpmux-file-chip, .acpmux-paste-chip",
        )) {
          const r = el.getBoundingClientRect();
          for (let node = el.parentElement; node && node !== scroller; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (style.overflowX === "visible" && style.overflowY === "visible" && style.clipPath === "none") continue;
            const c = node.getBoundingClientRect();
            rowClip = Math.max(rowClip, c.left - r.left, r.right - c.right, c.top - r.top, r.bottom - c.bottom);
          }
        }
        return { x: bubble.x, y: bubble.y, w: bubble.width, h: bubble.height, rowClipPx: Math.max(0, rowClip) };
      }, scroll);
    await measure(true);
    await page.waitForTimeout(60);
    const read = await measure(false);
    const top = read.y - 16;
    const bottom = read.y + read.h + 16;
    const clip = { x: 0, y: Math.max(0, top), width: 900, height: Math.min(640, bottom) - Math.max(0, top) };
    frames.push({
      ms,
      bubble: read,
      rowClipPx: Number(read.rowClipPx.toFixed(2)),
      cropCutPx: Math.round(Math.max(0, -top) + Math.max(0, bottom - 640)),
    });
    await page.screenshot({ path: path.join(OUT, `pop-${String(ms).padStart(3, "0")}.png`), clip });
  }
  fs.writeFileSync(
    path.join(OUT, "strip.json"),
    JSON.stringify({ case: CASE, engine: ENGINE, pop: POP, frames }, null, 2),
  );
  console.log(`send-pop-strip: wrote ${OUT} (${ENGINE}, case ${CASE}, pop ${POP})`);
} finally {
  await browser.close();
  await pane.close();
  fs.rmSync(out, { recursive: true, force: true });
}
