// l10n-allow-file: benchmark output, not shipped UI.
// Tab switch cost of the sliding selection indicator (ui/motion/SlidingIndicator.tsx), on the static gallery (as
// model-picker-open.bench.ts builds it), in Chromium and WebKit. Per implementation:
//   response      real mouse press and release on the next tab until the first animation frame in which that tab
//                 is marked selected (aria-selected / aria-pressed): that frame paints the new selection.
//   shift_frames  frames (of FOLLOW after that one) in which an item, the tab bar or the element after it moved or
//                 resized by more than half a px. The highlight itself is excluded: it travels by design, on
//                 transform. 0 means nothing around the tabs moved.
//   cls           Chromium layout-shift entries from the press to the end of FOLLOW frames.
//   settle        ms from the press until no animation runs in the document (the slide has ended).
//   idle_*        IDLE ms after the last switch settled: wakeups (bench/stability.ts), and Chromium renderer task ms.
// Implementations: the gallery's `today` (each item fills itself at once, the base behavior) and `pill-spring`
// (the picked indicator), and the ACP inspector's Wire / Session switch in the agent pane (its real surface).
//   bun bench/motion-tabs.bench.ts [contexts=5]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { perfRow, TARGET_MS } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle } from "./stability";

const CONTEXTS = Number(process.argv[2] ?? 5);
const SWITCHES = 6;
const FOLLOW = 30;
const IDLE = 2000;

type Impl = {
  name: string;
  entry: string;
  variant: string;
  /** The items, in order; the bench switches to the next one each time. */
  items: string;
  /** The elements whose boxes must not move. */
  still: string;
  open?: (page: Page) => Promise<void>;
};

const IMPLS: readonly Impl[] = [
  {
    name: "today",
    entry: "ui.motion-sliding-indicator",
    variant: "today",
    items: ".motion-demo-tabs .motion-demo-tab",
    still: ".motion-demo-tabs, .motion-demo-tab, .motion-demo-segmented, .motion-demo-receipt",
  },
  {
    name: "pill_spring",
    entry: "ui.motion-sliding-indicator",
    variant: "pill-spring",
    items: ".motion-demo-tabs .motion-demo-tab",
    still: ".motion-demo-tabs, .motion-demo-tab, .motion-demo-segmented, .motion-demo-receipt",
  },
  {
    name: "inspector",
    entry: "agent-pane.inspector",
    variant: "chat-menu",
    items: ".acpmux-inspector-views .acpmux-diff-tool",
    still:
      ".acpmux-inspector-views, .acpmux-inspector-views .acpmux-diff-tool, .acpmux-diff-header strong, .acpmux-inspector-state",
    open: async (page) => {
      // The variant's play may have opened the chat menu already; open it if not.
      const item = page.getByRole("menuitem", { name: "ACP inspector" });
      if (!(await item.isVisible().catch(() => false)))
        await page.getByRole("button", { name: "Chat actions" }).click();
      await item.click();
      await page.waitForSelector(".acpmux-inspector-views .acpmux-diff-tool");
    },
  },
];

/** In-page: arm a press-to-paint probe for item `index`. Resolves window.__mtSwitch. */
function armSwitch(args: { items: string; still: string; index: number; follow: number }) {
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
  const boxes = () =>
    [...document.querySelectorAll<HTMLElement>(args.still)].flatMap((el) => {
      const r = el.getBoundingClientRect();
      return [r.x, r.y, r.width, r.height];
    });
  const selected = () => {
    const item = document.querySelectorAll<HTMLElement>(args.items)[args.index];
    return item?.getAttribute("aria-selected") === "true" || item?.getAttribute("aria-pressed") === "true";
  };
  const running = () => document.getAnimations().some((animation) => animation.playState === "running");
  w.__mtSwitch = new Promise((resolve) => {
    let start = 0;
    document.addEventListener("pointerdown", () => (start = performance.now()), { capture: true, once: true });
    let first = 0;
    let before = boxes();
    let moved = 0;
    let frames = 0;
    let settle = 0;
    const tick = () => {
      if (start && !first && selected()) {
        first = performance.now();
        before = boxes();
      } else if (first) {
        frames += 1;
        const now = boxes();
        if (now.length !== before.length || now.some((value, at) => Math.abs(value - before[at]!) > 0.5)) moved += 1;
        before = now;
        if (!settle && !running()) settle = performance.now();
        if (frames >= args.follow && settle) {
          observer?.disconnect();
          resolve({ ms: first - start, moved, cls: shifts.reduce((a, b) => a + b, 0), settle: settle - start });
          return;
        }
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
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

type Sample = { ms: number[]; moved: number[]; cls: number[]; settle: number[] };
type Switched = { ms: number; moved: number; cls: number; settle: number };

async function switchTo(page: Page, impl: Impl, index: number): Promise<Switched> {
  await page.evaluate(armSwitch, { items: impl.items, still: impl.still, index, follow: FOLLOW });
  const box = (await page.locator(impl.items).nth(index).boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.up();
  const got = await Promise.race([
    page.evaluate(() => (window as unknown as { __mtSwitch: Promise<Switched> }).__mtSwitch),
    new Promise<null>((r) => setTimeout(() => r(null), 5000)),
  ]);
  if (!got) throw new Error(`${impl.name}: item ${index} never painted selected`);
  return got;
}

async function run(browser: Browser, isChromium: boolean, base: string, impl: Impl) {
  const sample: Sample = { ms: [], moved: [], cls: [], settle: [] };
  let idle: { wakeups: number; cpuMs: number | null; sources: string[] } | undefined;
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
      if (impl.open) await impl.open(page);
      await page.waitForTimeout(500);
      const count = await page.locator(impl.items).count();
      if (count < 2) throw new Error(`${impl.name}: ${count} items`);
      for (let s = 1; s <= SWITCHES; s++) {
        const got = await switchTo(page, impl, s % count);
        sample.ms.push(got.ms);
        sample.moved.push(got.moved);
        sample.cls.push(got.cls);
        sample.settle.push(got.settle);
        await page.waitForTimeout(150);
      }
      if (c === CONTEXTS - 1) {
        // The last slide ended: one idle window with the tabs still.
        await page.mouse.move(2, 2);
        await page.waitForTimeout(300);
        const [quiet] = await measureIdle([{ page, cdp }], IDLE);
        idle = { wakeups: quiet!.wakeups, cpuMs: quiet!.cpuMs, sources: quiet!.sources };
      }
    } finally {
      await context.close();
    }
  }
  return { sample, idle };
}

try {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "motion-tabs-gallery-"));
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
    console.log(`motion-tabs: ${engine}, ${CONTEXTS} contexts x ${SWITCHES} switches`);
    console.log("impl | response p50/p95 | shift frames max | cls max | settle p50/p95 | idle wakeups | cpu ms");
    for (const impl of IMPLS) {
      try {
        const { sample, idle } = await run(browser, isChromium, base, impl);
        const name = `motion_tabs.${impl.name}${isChromium ? "" : ".webkit"}`;
        const moved = Math.max(...sample.moved);
        const cls = Math.max(...sample.cls);
        console.log(
          `${impl.name} | ${pct(sample.ms, 0.5).toFixed(1)}/${pct(sample.ms, 0.95).toFixed(1)} | ${moved} | ` +
            `${isChromium ? cls.toFixed(4) : "-"} | ${pct(sample.settle, 0.5).toFixed(1)}/${pct(sample.settle, 0.95).toFixed(1)} | ` +
            `${idle?.wakeups} | ${idle?.cpuMs === null || idle?.cpuMs === undefined ? "-" : idle.cpuMs.toFixed(1)}`,
        );
        for (const source of idle?.sources.slice(0, 4) ?? []) console.log(`  woke: ${source}`);
        perfRow({
          name: `${name}.response`,
          p50: pct(sample.ms, 0.5),
          p95: pct(sample.ms, 0.95),
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
        perfRow({ name: `${name}.settle`, p50: pct(sample.settle, 0.5), p95: pct(sample.settle, 0.95), target: 280 }); // the 240 ms slide plus the frame that paints the click
        if (idle) {
          perfRow({
            name: `${name}.idle_wakeups`,
            p50: idle.wakeups,
            p95: idle.wakeups,
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
          `motion-tabs: ${engine} ${impl.name} FAILED: ${error instanceof Error ? error.stack : String(error)}`,
        );
      }
    }
  }
  if (failed) process.exitCode = 1;
} finally {
  await release();
}
