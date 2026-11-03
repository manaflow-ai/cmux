// l10n-allow-file: benchmark output, not shipped UI.
// SPIKE bench: the production model picker (agent-pane.model-picker) beside the Base UI composition spike
// (ui.spike-base-ui-model-picker), in Chromium and WebKit, on the static gallery (as ui-stability.bench.ts builds it).
// Per implementation:
//   open          real mouse press on the trigger (Playwright mouse.down) until the first animation frame in which
//                 the popup is in the DOM, visible and laid out: that frame paints it. 1 cold + WARM-1 warm per context.
//   shift_frames  frames (of the FOLLOW frames after that first one) in which the popup's box moved or resized by
//                 more than half a px: 0 when the first frame is the final frame.
//   cls           Chromium layout-shift entries from the press to the end of FOLLOW frames (input-adjacent included).
//   type          a key press in the search field until the first frame after the list's DOM changed.
//   idle_*        IDLE window with the picker open and still: wakeups (timers, intervals, frames, idle callbacks,
//                 running animations, bench/stability.ts), long tasks, and Chromium renderer task ms (CDP).
//   bun bench/model-picker-open.bench.ts [contexts=5]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { perfRow, TARGET_MS } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle } from "./stability";

const CONTEXTS = Number(process.argv[2] ?? 5);
const WARM = 4;
const FOLLOW = 30;
const IDLE = 2000;
const QUERY = "son";

type Impl = { name: string; entry: string; variant: string; trigger: string; popup: string; input: string };
const IMPLS: readonly Impl[] = [
  {
    name: "current",
    entry: "agent-pane.model-picker",
    variant: "updated",
    trigger: ".acpmux-model .acpmux-picker-button",
    popup: ".acpmux-mp",
    input: '.acpmux-mp input[role="combobox"]',
  },
  {
    name: "spike",
    entry: "ui.spike-base-ui-model-picker",
    variant: "closed",
    trigger: ".spike-mp-trigger",
    popup: ".spike-mp",
    input: ".spike-mp-search",
  },
];

/** In-page: arm a press-to-paint probe. Resolves (via window.__mpOpen) with ms and shift data. */
function armOpen(args: { popup: string; follow: number }) {
  const w = window as unknown as Record<string, unknown>;
  const shifts: number[] = [];
  let observer: PerformanceObserver | undefined;
  try {
    observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) shifts.push((entry as unknown as { value: number }).value);
    });
    observer.observe({ type: "layout-shift", buffered: false });
  } catch {
    observer = undefined;
  }
  w.__mpOpen = new Promise((resolve) => {
    let start = 0;
    document.addEventListener("pointerdown", () => (start = performance.now()), { capture: true, once: true });
    let first = 0;
    let box: number[] | undefined;
    let moved = 0;
    let frames = 0;
    const visible = (el: HTMLElement | null) => {
      if (!el) return null;
      const style = getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      if (style.visibility === "hidden" || style.display === "none" || rect.width < 1 || rect.height < 1) return null;
      return [rect.x, rect.y, rect.width, rect.height];
    };
    const tick = () => {
      const now = visible(document.querySelector<HTMLElement>(args.popup));
      if (start && !first && now) {
        first = performance.now();
        box = now;
      } else if (first) {
        frames += 1;
        if (!now || now.some((value, at) => Math.abs(value - box![at]!) > 0.5)) moved += 1;
        if (now) box = now;
        if (frames >= args.follow) {
          observer?.disconnect();
          resolve({ ms: first - start, moved, cls: shifts.reduce((a, b) => a + b, 0) });
          return;
        }
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

/** In-page: time one key press in the field until the first frame after the popup's DOM changed. */
function armKey(args: { popup: string }) {
  const w = window as unknown as Record<string, unknown>;
  w.__mpKey = new Promise((resolve) => {
    let start = 0;
    let changed = false;
    const popup = document.querySelector(args.popup)!;
    const mo = new MutationObserver(() => (changed = true));
    mo.observe(popup, { subtree: true, childList: true, characterData: true, attributes: true });
    document.addEventListener("keydown", () => (start = performance.now()), { capture: true, once: true });
    const tick = () => {
      if (start && changed) {
        mo.disconnect();
        resolve(performance.now() - start);
        return;
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

function armLongTasks() {
  const w = window as unknown as Record<string, unknown>;
  w.__mpLong = 0;
  try {
    new PerformanceObserver((list) => {
      w.__mpLong = (w.__mpLong as number) + list.getEntries().length;
    }).observe({ type: "longtask" });
  } catch {
    w.__mpLong = -1;
  }
}

const pct = (values: readonly number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((sorted.length - 1) * p + 0.5))]!;
};

const webviews = path.resolve(import.meta.dir, "..");
const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of [...releases].reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};

type Sample = { open: number[]; first: number[]; moved: number[]; cls: number[]; type: number[] };

async function openOnce(page: Page, impl: Impl) {
  await page.evaluate(armOpen, { popup: impl.popup, follow: FOLLOW });
  const box = (await page.locator(impl.trigger).first().boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  const opened = page.evaluate(() => (window as unknown as { __mpOpen: Promise<unknown> }).__mpOpen) as Promise<{
    ms: number;
    moved: number;
    cls: number;
  }>;
  // A trigger that opens on click, not on the press: release after 1 s; the time then includes the hold.
  const held = await Promise.race([
    opened.then(() => false),
    new Promise<boolean>((r) => setTimeout(() => r(true), 1000)),
  ]);
  if (held) console.log(`  ${impl.name}: did not open on the press; released`);
  await page.mouse.up();
  const late = await Promise.race([opened, new Promise<null>((r) => setTimeout(() => r(null), 5000))]);
  if (!late) {
    const why = await page.evaluate((sel) => {
      const el = document.querySelector<HTMLElement>(sel);
      if (!el) return `no ${sel}; active=${document.activeElement?.outerHTML.slice(0, 200)}`;
      const r = el.getBoundingClientRect();
      return `${sel} ${r.width}x${r.height} visibility=${getComputedStyle(el).visibility} display=${getComputedStyle(el).display}`;
    }, impl.popup);
    throw new Error(`${impl.name}: never painted open (${why})`);
  }
  return late;
}

async function run(browser: Browser, isChromium: boolean, base: string, impl: Impl) {
  const sample: Sample = { open: [], first: [], moved: [], cls: [], type: [] };
  let idle: { wakeups: number; cpuMs: number | null; long: number; sources: string[] } | undefined;
  for (let c = 0; c < CONTEXTS; c++) {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 }, colorScheme: "dark" });
    await addStabilityProbe(context, { boxes: false });
    const page = await context.newPage();
    const cdp = await cpuSession(page, isChromium);
    try {
      await page.goto(`${base}/frame.html?entry=${impl.entry}&variant=${impl.variant}&colorScheme=dark&width=normal`, {
        waitUntil: "domcontentloaded",
      });
      await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""), {
        timeout: 90_000,
        polling: 100,
      });
      if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) !== "1")
        throw new Error(`${impl.entry}#${impl.variant}: the stage failed`);
      await page.waitForTimeout(500);
      for (let o = 0; o < WARM; o++) {
        const got = await openOnce(page, impl);
        sample.open.push(got.ms);
        if (o === 0) sample.first.push(got.ms);
        sample.moved.push(got.moved);
        sample.cls.push(got.cls);
        const last = o === WARM - 1;
        if (last && c === CONTEXTS - 1) {
          // The picker is open and still: one idle window.
          await page.waitForTimeout(300);
          await page.evaluate(armLongTasks);
          const [quiet] = await measureIdle([{ page, cdp }], IDLE);
          idle = {
            wakeups: quiet!.wakeups,
            cpuMs: quiet!.cpuMs,
            long: await page.evaluate(() => (window as unknown as { __mpLong: number }).__mpLong),
            sources: quiet!.sources,
          };
        }
        if (last) {
          // Typing: focus the field (both pickers focus it on open; this makes the start equal) and type the query.
          await page.locator(impl.input).first().focus();
          for (const char of QUERY) {
            await page.evaluate(armKey, { popup: impl.popup });
            await page.keyboard.press(char);
            sample.type.push(
              (await page.evaluate(() => (window as unknown as { __mpKey: Promise<number> }).__mpKey)) as number,
            );
            await page.waitForTimeout(100);
          }
        }
        await page.keyboard.press("Escape");
        await page.waitForTimeout(300);
      }
    } finally {
      await context.close();
    }
  }
  return { sample, idle };
}

try {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "model-picker-gallery-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const strings = Bun.spawnSync(["node", "scripts/pages/gen-strings.mjs"], { cwd: webviews, stdout: "ignore" });
  if (strings.exitCode !== 0) throw new Error(`gen-strings exited ${strings.exitCode}: ${strings.stderr.toString()}`);
  process.env.CMUX_GALLERY_OUT_DIR = out;
  const { build } = await import("vite");
  await build({ root: webviews, configFile: path.join(webviews, "vite.config.gallery.ts"), logLevel: "error" });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = decodeURIComponent(new URL(request.url).pathname);
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const base = `http://127.0.0.1:${statics.port}`;
  let failed = 0;
  for (const [engine, type] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    const isChromium = engine === "chromium";
    const browser = await type.launch({ headless: true });
    releases.push(() => browser.close());
    console.log(`model-picker-open: ${engine}, ${CONTEXTS} contexts x ${WARM} opens`);
    console.log(
      "impl | open p50/p95 | first-open p50 | shift frames max | cls max | type p50/p95 | idle wakeups | long | cpu ms",
    );
    for (const impl of IMPLS) {
      try {
        const { sample, idle } = await run(browser, isChromium, base, impl);
        const name = `model_picker_open.${impl.name}${isChromium ? "" : ".webkit"}`;
        const open50 = pct(sample.open, 0.5);
        const open95 = pct(sample.open, 0.95);
        const type50 = pct(sample.type, 0.5);
        const type95 = pct(sample.type, 0.95);
        const moved = Math.max(...sample.moved);
        const cls = Math.max(...sample.cls);
        console.log(
          `${impl.name} | ${open50.toFixed(1)}/${open95.toFixed(1)} | ${pct(sample.first, 0.5).toFixed(1)} | ${moved} | ` +
            `${isChromium ? cls.toFixed(4) : "-"} | ${type50.toFixed(1)}/${type95.toFixed(1)} | ${idle?.wakeups} | ` +
            `${idle?.long} | ${idle?.cpuMs === null || idle?.cpuMs === undefined ? "-" : idle.cpuMs.toFixed(1)}`,
        );
        for (const source of idle?.sources.slice(0, 4) ?? []) console.log(`  woke: ${source}`);
        perfRow({ name: `${name}.open`, p50: open50, p95: open95, target: TARGET_MS.response });
        perfRow({
          name: `${name}.open_first`,
          p50: pct(sample.first, 0.5),
          p95: pct(sample.first, 0.95),
          target: TARGET_MS.response,
        });
        perfRow({
          name: `${name}.shift_frames`,
          p50: pct(sample.moved, 0.5),
          p95: moved,
          unit: "count",
          target: 0,
          floor: 0.5,
        });
        if (isChromium)
          perfRow({ name: `${name}.cls`, p50: pct(sample.cls, 0.5), p95: cls, unit: "score", target: 0, floor: 0.001 });
        perfRow({ name: `${name}.type`, p50: type50, p95: type95, target: TARGET_MS.response });
        if (idle) {
          perfRow({
            name: `${name}.idle_wakeups`,
            p50: idle.wakeups,
            p95: idle.wakeups,
            unit: "count",
            target: 0,
            floor: 0.5,
          });
          if (idle.long >= 0)
            perfRow({
              name: `${name}.idle_long_tasks`,
              p50: idle.long,
              p95: idle.long,
              unit: "count",
              target: 0,
              floor: 0.5,
            });
          if (idle.cpuMs !== null)
            perfRow({ name: `${name}.idle_cpu_ms`, p50: idle.cpuMs, p95: idle.cpuMs, target: 5, floor: 2 });
        }
      } catch (error) {
        failed += 1;
        console.log(
          `model-picker-open: ${engine} ${impl.name} FAILED: ${error instanceof Error ? error.stack : String(error)}`,
        );
      }
    }
  }
  if (failed) process.exitCode = 1;
} finally {
  await release();
}
