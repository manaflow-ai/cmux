// l10n-allow-file: benchmark output, not shipped UI.
// A fast fling through a long chat, and clicks along its prompt rail, on a profile with many sessions.
// Leo, 2026-11-22: "apparently austin was maybe still getting lags on scrolling in general when he's scrolling
// really fast, and he had lots of workspaces/sessions... we want to make sure we're stress testing and benching
// and identifying that as well. we can probably squeeze harder. especially cuz i was noticing me clicking along
// the scroll rail sometimes delayed/didn't load"
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon, production React) in two
// pages of one Chromium renderer (`--renderer-process-limit=1`, as the app runs its agent pages): the shown
// one opens a long paged chat (TURNS full turns: prose, a read and every third an edit, so its history pages
// in as a real one does), the other a hidden long chat. Both list SIZE sessions, and their mock daemon changes
// a random listed one RATE times a second, as a busy daemon's `session_changed` does. Per size:
//   fling      real wheel input at FLING_PX a notch every 8 ms (a fast trackpad fling, about 7,500 px/s),
//              up for half the time and down for the rest: the frame intervals (p50/p95/max), the frames
//              dropped against 60 Hz, the frames' own work, and blank frames, painted frames whose
//              transcript viewport shows no row with text (the fling outran the rows).
//   rail       clicks at CLICKS places along the prompt rail, spread over the whole chat (most of them on
//              prompts whose page is not loaded yet): click to the first painted frame that shows the
//              target prompt in the transcript (p50/p95/max), and the clicks that never showed it within
//              LOAD_MS (a click that "didn't load").
//   bun bench/chat-fast-scroll.bench.ts [--sizes 200,500,1000] [--turns 1500] [--seconds 4] [--clicks 16]
//     [--rate 4] [--fling 400] [--cpu 1]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import type { CDPSession, Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { installReactWatch, requireProductionReact } from "./support/benchPage";
import { perfRow, TARGET_MS } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const SIZES = (flag("--sizes") ?? "200,500,1000").split(",").map(Number);
const TURNS = Number(flag("--turns") ?? 1500);
const SECONDS = Number(flag("--seconds") ?? 4);
const CLICKS = Number(flag("--clicks") ?? 16);
const RATE = Number(flag("--rate") ?? 4);
const FLING_PX = Number(flag("--fling") ?? 400);
const CPU = Number(flag("--cpu") ?? 1);
/// A click whose prompt is not on screen by then never loaded, as a person reads it.
const LOAD_MS = Number(flag("--load-ms") ?? 3000);
const PROFILE = argv.includes("--profile");
/// --trace: the layouts and style recalcs over each measured part, and the scripts that forced them.
const TRACE = argv.includes("--trace");
const NOMINAL_MS = 1000 / 60;
const NOTCH_MS = 8;
if (SIZES.some((size) => !Number.isInteger(size) || size < 0) || !(TURNS >= 100) || !(CLICKS >= 2)) {
  console.error("usage: bun bench/chat-fast-scroll.bench.ts [--sizes 200,500,1000] [--turns 1500] [--clicks 16]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;
const round1 = (value: number) => Math.round(value * 10) / 10;

/// In the page: every `1000 / rate` ms one listed session changes, the way the daemon tells a watcher.
async function installDriver({ size, rate }: { size: number; rate: number }) {
  type MockModule = typeof import("../src/agent-session/acpmux/mock");
  const mockUrl = "/mock.ts";
  const { MockAcpmuxSocket } = (await import(/* @vite-ignore */ mockUrl)) as MockModule;
  const daemon = MockAcpmuxSocket.live;
  if (!daemon) throw new Error("no mock daemon");
  // --trace: the daemon requests, by when each was asked and answered (`__asks`).
  const asks: { method: string; at: number; ms: number; params: string }[] = [];
  (window as any).__asks = asks;
  const answer = (daemon as any).answer.bind(daemon);
  (daemon as any).answer = async (method: string, params: Record<string, any>) => {
    const at = performance.now();
    try {
      return await answer(method, params);
    } finally {
      const { sessionId: _, ...rest } = params ?? {};
      asks.push({ method, at, ms: performance.now() - at, params: JSON.stringify(rest).slice(0, 120) });
    }
  };
  let round = 0;
  let timer: ReturnType<typeof setInterval> | undefined;
  (window as any).__scale = {
    start() {
      if (rate <= 0 || size <= 0 || timer) return;
      timer = setInterval(() => {
        round += 1;
        daemon.changeSession(`listed-${Math.floor(Math.random() * size)}`, (current: Record<string, any>) => ({
          status: current.status === "running" ? "idle" : "running",
          updatedAt: Date.now(),
        }));
      }, 1000 / rate);
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = undefined;
      return round;
    },
  };
}

type Profile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples?: number[];
  timeDeltas?: number[];
};
/// --profile: the functions with the most self time over one measured part (every page of the renderer).
async function profiled<T>(cdp: CDPSession, label: string, run: () => Promise<T>): Promise<T> {
  if (!PROFILE) return run();
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
  await cdp.send("Profiler.start");
  const result = await run();
  const { profile } = (await cdp.send("Profiler.stop")) as { profile: Profile };
  if (process.env.PROFILE_DIR)
    await Bun.write(
      path.join(process.env.PROFILE_DIR, `${label.replace(/\W+/g, "-")}-${Date.now()}.cpuprofile`),
      JSON.stringify(profile),
    );
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const self = new Map<string, number>();
  let total = 0;
  (profile.samples ?? []).forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame || frame.functionName === "(idle)" || frame.functionName === "(program)") return;
    const ms = (profile.timeDeltas?.[index + 1] ?? 0) / 1000;
    total += ms;
    const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").slice(-2).join("/").split("?")[0]}:${frame.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + ms);
  });
  // A native frame (a layout read, a DOM removal) by the script frames that called it: the cost is the caller's.
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const callers = new Map<string, number>();
  (profile.samples ?? []).forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame || frame.url || frame.functionName.startsWith("(")) return;
    const ms = (profile.timeDeltas?.[index + 1] ?? 0) / 1000;
    const chain: string[] = [];
    for (let at = parent.get(id); at !== undefined && chain.length < 3; at = parent.get(at)) {
      const up = byId.get(at)?.callFrame;
      if (up?.url)
        chain.push(`${up.functionName || "(anon)"}@${up.url.split("/").pop()!.split("?")[0]}:${up.lineNumber + 1}`);
    }
    const key = `${frame.functionName} < ${chain.join(" < ")}`;
    callers.set(key, (callers.get(key) ?? 0) + ms);
  });
  const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 40);
  const natives = [...callers].sort((a, b) => b[1] - a[1]).slice(0, 15);
  console.log(
    `PROFILE ${label} total ${Math.round(total)} ms self:\n` +
      top.map(([k, ms]) => `  ${ms.toFixed(1).padStart(8)} ms  ${k}`).join("\n") +
      "\n native by caller:\n" +
      natives.map(([k, ms]) => `  ${ms.toFixed(1).padStart(8)} ms  ${k}`).join("\n"),
  );
  return result;
}

type TraceEvent = { name: string; ph: string; dur?: number; tid: number; args?: any };
/// --trace: over one measured part, the renderer main thread's layouts and style recalcs (count, ms), and the script
/// frames that forced one (a read of layout before the frame's own), by their total ms.
async function traced<T>(page: Page, label: string, run: () => Promise<T>): Promise<T> {
  if (!TRACE) return run();
  const browser = page.context().browser()!;
  await browser.startTracing(page, {
    categories: ["devtools.timeline", "disabled-by-default-devtools.timeline.stack"],
  });
  const result = await run();
  const events = (JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: TraceEvent[] }).traceEvents;
  const sum = new Map<string, { n: number; ms: number }>();
  const forced = new Map<string, number>();
  const add = (key: string, ms: number) => {
    const was = sum.get(key) ?? { n: 0, ms: 0 };
    sum.set(key, { n: was.n + 1, ms: was.ms + ms });
  };
  for (const event of events) {
    if (
      event.ph !== "X" ||
      !["Layout", "UpdateLayoutTree", "Paint", "FunctionCall", "EventDispatch"].includes(event.name)
    )
      continue;
    const ms = (event.dur ?? 0) / 1000;
    add(event.name, ms);
    const stack = event.args?.beginData?.stackTrace as
      | { functionName: string; url: string; lineNumber: number }[]
      | undefined;
    if ((event.name === "Layout" || event.name === "UpdateLayoutTree") && stack?.length) {
      const top = stack
        .slice(0, 3)
        .map((f) => `${f.functionName || "(anon)"}@${f.url.split("/").pop()?.split("?")[0]}:${f.lineNumber + 1}`)
        .join(" < ");
      forced.set(`${event.name} ${top}`, (forced.get(`${event.name} ${top}`) ?? 0) + ms);
    }
  }
  console.log(
    `TRACE ${label}: ` +
      [...sum].map(([k, v]) => `${k} ${v.n}x ${v.ms.toFixed(1)}ms`).join(", ") +
      "\n" +
      [...forced]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 15)
        .map(([k, ms]) => `  ${ms.toFixed(1).padStart(7)} ms forced ${k}`)
        .join("\n"),
  );
  return result;
}

async function openChat(page: Page, port: number, size: number, turns: number) {
  await page.addInitScript((count) => {
    (globalThis as { cmuxAcpmuxMockListSize?: number }).cmuxAcpmuxMockListSize = count;
  }, size);
  await installPaintedFrames(page);
  await installReactWatch(page);
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 120_000 });
  await requireProductionReact(page, { dev: false });
  const seeded = (await page.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: false }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(".acpmux-scroll").first().waitFor({ timeout: 60_000 });
  await page.evaluate(installDriver, { size, rate: RATE });
}

/// Starts counting, in the shown page, the painted frames whose transcript viewport has no row with text.
async function startBlankWatch(page: Page) {
  await page.evaluate(() => {
    const probe = window as unknown as { __blank: { frames: number; blank: number; stop: boolean } };
    probe.__blank = { frames: 0, blank: 0, stop: false };
    window.cmuxAfterPaint(() => {
      const state = probe.__blank;
      if (state.stop) return false;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      if (!scroller) return true;
      state.frames += 1;
      const view = scroller.getBoundingClientRect();
      // The middle third of the viewport: a row edge or the room under the latest row is no blank.
      const top = view.top + view.height / 3;
      const bottom = view.bottom - view.height / 3;
      const filled = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].some((row) => {
        const box = row.getBoundingClientRect();
        return box.bottom > top && box.top < bottom && box.height > 0 && (row.textContent ?? "").trim() !== "";
      });
      if (!filled) state.blank += 1;
      return true;
    });
  });
}
async function stopBlankWatch(page: Page): Promise<{ frames: number; blank: number }> {
  return page.evaluate(() => {
    const probe = window as unknown as { __blank: { frames: number; blank: number; stop: boolean } };
    probe.__blank.stop = true;
    return { frames: probe.__blank.frames, blank: probe.__blank.blank };
  });
}

async function fling(page: Page, cdp: CDPSession) {
  const box = (await page.locator(".acpmux-scroll").first().boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await startBlankWatch(page);
  const started = await page.evaluate(() => (window as any).cmuxAcpmuxDebug.tickWatch());
  if ((started as Record<string, unknown>).error) throw new Error(`tickWatch: ${JSON.stringify(started)}`);
  const before = (await cdp.send("Performance.getMetrics")).metrics.find((m) => m.name === "TaskDuration")!.value;
  const wallBefore = performance.now();
  // The chat opens at its latest message: the fling goes up first, then back down.
  while (performance.now() - wallBefore < SECONDS * 1000) {
    const up = performance.now() - wallBefore < (SECONDS * 1000) / 2;
    await page.mouse.wheel(0, up ? -FLING_PX : FLING_PX);
    await page.waitForTimeout(NOTCH_MS);
  }
  const wall = performance.now() - wallBefore;
  const watch = (await page.evaluate(
    (nominal) => (window as any).cmuxAcpmuxDebug.tickWatch({ stop: true, nominal_ms: nominal }),
    NOMINAL_MS,
  )) as Record<string, any>;
  const after = (await cdp.send("Performance.getMetrics")).metrics.find((m) => m.name === "TaskDuration")!.value;
  const blank = await stopBlankWatch(page);
  const frames = watch.frames ?? {};
  return {
    frames: frames.frames as number,
    frame_p50: frames.p50_ms as number,
    frame_p95: frames.p95_ms as number,
    frame_max: frames.max_ms as number,
    dropped: frames.dropped_frames as number,
    work_p95: (watch.work?.p95_ms ?? null) as number | null,
    busy_pct: round1((((after - before) * 1000) / wall) * 100),
    blank_frames: blank.blank,
    painted_frames: blank.frames,
    moved_frames: watch.moved_frames as number,
  };
}

/// Clicks at CLICKS places along the prompt rail: each scrolls the rail's own list to the place (as a
/// person's wheel over the rail does), then clicks the tick there with the real mouse.
async function railClicks(page: Page, around: <T>(run: () => Promise<T>) => Promise<T> = (run) => run()) {
  const rail = page.locator(".acpmux-minimap__list").first();
  await rail.waitFor({ timeout: 30_000 });
  const count = Number(await rail.locator("[aria-setsize]").first().getAttribute("aria-setsize"));
  if (!(count > 10)) throw new Error(`The rail lists ${count} prompts`);
  const samples: { index: number; ms: number | null; frames: number }[] = [];
  for (let sample = 0; sample < CLICKS; sample += 1) {
    // Spread over the whole chat, oldest to newest and back, never the same place twice in a row.
    const index = Math.floor(((sample * 0.618034) % 1) * (count - 2)) + 1;
    // The rail follows the transcript, and history still filling in after the last click moves it: scroll it to the
    // tick again each frame until the tick is drawn and still. Each write comes with a wheel event on the list, as a
    // person's wheel over the rail does, so the rail holds the place it was browsed to (`railBrowsing`) and does not
    // follow the transcript away from the tick under the pointer before the press.
    // The box is read in the same frame it was found drawn in: a locator's box, read after, can find the tick gone
    // again as the rail moves under it.
    const target = await rail.evaluate(async (node, index) => {
      for (let frame = 0; frame < 300; frame += 1) {
        node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true, cancelable: true }));
        node.scrollTop = index * 10 - node.clientHeight / 2;
        await window.cmuxPaintFrame();
        const tick = node.querySelector(`[data-tick="${index}"]`);
        const box = tick?.getBoundingClientRect();
        const view = node.getBoundingClientRect();
        if (box && box.height > 0 && box.top >= view.top && box.bottom <= view.bottom)
          return { x: box.left, y: box.top, width: box.width, height: box.height };
      }
      return null;
    }, index);
    if (!target) throw new Error(`Tick ${index} was not drawn in the rail's view in 300 frames`);
    await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2);
    await page.evaluate(
      ({ index, loadMs, trace }) => {
        (window as any).__frames = [];
        const probe = window as unknown as { __click: { ms: number | null; frames: number } | null };
        probe.__click = null;
        // The tick names its prompt ("Message 793 of 1381: Turn 911: ..."); the rail lists only the prompts it knows.
        const label = document.querySelector(`[data-tick="${index}"]`)?.getAttribute("aria-label") ?? "";
        const prompt = `Turn ${label.match(/Turn (\d+):/)?.[1] ?? "?"}:`;
        addEventListener(
          "pointerdown",
          (event: PointerEvent) => {
            const start = performance.now();
            if (trace) {
              const hit = (event.target as Element | null)?.closest?.("[data-tick]");
              const box = document.querySelector(`[data-tick="${index}"]`)?.getBoundingClientRect();
              ((window as any).__frames ??= []).push(
                `down at ${event.clientX},${event.clientY} hit=${hit?.getAttribute("data-tick") ?? (event.target as Element)?.className} tick=${box ? `${Math.round(box.left)},${Math.round(box.top)} ${Math.round(box.width)}x${Math.round(box.height)}` : "gone"}`,
              );
            }
            let frames = 0;
            window.cmuxAfterPaint(() => {
              frames += 1;
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const view = scroller.getBoundingClientRect();
              const shown = [...scroller.querySelectorAll<HTMLElement>(".cv-user__bubble")].some((bubble) => {
                if (!(bubble.textContent ?? "").trim().startsWith(prompt)) return false;
                const box = bubble.getBoundingClientRect();
                return box.height > 0 && box.bottom > view.top && box.top < view.bottom;
              });
              const ms = performance.now() - start;
              if (trace) {
                const bubble = [...scroller.querySelectorAll<HTMLElement>(".cv-user__bubble")].find((each) =>
                  (each.textContent ?? "").trim().startsWith(prompt),
                );
                const rows = scroller.querySelectorAll(".acpmux-row").length;
                ((window as any).__frames ??= []).push(
                  `${Math.round(ms)}ms top=${Math.round(scroller.scrollTop)} h=${scroller.scrollHeight} rows=${rows} target=${bubble ? Math.round(bubble.getBoundingClientRect().top - view.top) : "none"}`,
                );
              }
              if (shown) {
                probe.__click = { ms, frames };
                return false;
              }
              if (ms > loadMs) {
                const seen = [...scroller.querySelectorAll<HTMLElement>(".cv-user__bubble")]
                  .filter((bubble) => {
                    const box = bubble.getBoundingClientRect();
                    return box.bottom > view.top && box.top < view.bottom;
                  })
                  .map((bubble) => (bubble.textContent ?? "").trim().slice(0, 16));
                probe.__click = { ms: null, frames, seen, prompt } as never;
                return false;
              }
              return true;
            });
          },
          { capture: true, once: true },
        );
      },
      { index, loadMs: LOAD_MS, trace: TRACE },
    );
    // fixed-wait: the pointer rests on the tick (its preview card opens) before the press, as a person's does.
    await page.waitForTimeout(500);
    if (TRACE) await page.evaluate(() => ((window as any).__asks.length = 0));
    const pressedAt = TRACE ? await page.evaluate(() => performance.now()) : 0;
    await around(async () => {
      await page.mouse.down();
      await page.mouse.up();
      await page.waitForFunction(() => (window as any).__click, null, { timeout: LOAD_MS + 5_000 });
    });
    const result = (await page.evaluate(() => (window as any).__click)) as { ms: number | null; frames: number };
    samples.push({ index, ...result });
    if (TRACE) {
      const asks = (await page.evaluate(() => (window as any).__asks)) as {
        method: string;
        at: number;
        ms: number;
        params: string;
      }[];
      console.log(
        `ASKS click ${index} (${result.ms === null ? "not loaded" : Math.round(result.ms) + " ms"}):\n` +
          asks
            .map((a) => `  +${Math.round(a.at - pressedAt)} ms ${a.method} ${Math.round(a.ms)} ms ${a.params}`)
            .join("\n") +
          "\n" +
          ((await page.evaluate(() => (window as any).__frames)) as string[]).map((f) => `  frame ${f}`).join("\n"),
      );
    }
    // fixed-wait: the jump's settle and any page it read finish before the next click, as a person reads.
    await page.waitForTimeout(250);
  }
  const loaded = samples.filter((s) => s.ms !== null).map((s) => s.ms!);
  return {
    prompts: count,
    clicks: samples.length,
    p50: round1(pct(loaded, 0.5)),
    p95: round1(pct(loaded, 0.95)),
    max: round1(Math.max(0, ...loaded)),
    not_loaded: samples.length - loaded.length,
    samples,
  };
}

process.env.NODE_ENV = "production";
const { createServer } = await import("vite");
const vite = await createServer({
  mode: "production",
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const results: Record<string, unknown>[] = [];
try {
  await vite.listen();
  await warmViteServer(vite, "/?mock");
  const { port } = vite.httpServer!.address() as { port: number };
  for (const size of SIZES) {
    const browser = await chromium.launch({ headless: true, args: ["--renderer-process-limit=1"] });
    try {
      const context = await browser.newContext({ viewport: { width: 1100, height: 820 } });
      const hidden = await context.newPage();
      await openChat(hidden, port, size, TURNS);
      const shown = await context.newPage();
      await openChat(shown, port, size, TURNS);
      await shown.bringToFront();
      const cdp = await context.newCDPSession(shown);
      await cdp.send("Performance.enable");
      if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
      for (const page of [hidden, shown]) await page.evaluate(() => (window as any).__scale.start());
      // fixed-wait: the change stream reaches its steady state before the measured input.
      await shown.waitForTimeout(1500);
      const flung = await traced(shown, `fling n=${size}`, () =>
        profiled(cdp, `fling n=${size}`, () => fling(shown, cdp)),
      );
      // fixed-wait: the fling's pages and settle finish before the rail is clicked.
      await shown.waitForTimeout(1000);
      const clicked = await railClicks(
        shown,
        PROFILE || TRACE
          ? (run) => traced(shown, `rail-click n=${size}`, () => profiled(cdp, `rail-click n=${size}`, run))
          : undefined,
      );
      const changes = (
        await Promise.all([hidden, shown].map((page) => page.evaluate(() => (window as any).__scale.stop())))
      ).reduce((sum: number, value: number) => sum + value, 0);
      const row = {
        size,
        turns: TURNS,
        rate: RATE,
        cpu: CPU,
        fling_px: FLING_PX,
        changes,
        fling: flung,
        rail: { ...clicked, samples: undefined },
      };
      results.push({ ...row, rail_samples: clicked.samples });
      console.log(
        `n=${size} turns=${TURNS}: fling frames ${flung.frames} p50 ${flung.frame_p50} p95 ${flung.frame_p95} max ${flung.frame_max} ms, ` +
          `dropped ${flung.dropped}, blank ${flung.blank_frames}/${flung.painted_frames}, busy ${flung.busy_pct} %; ` +
          `rail click (${clicked.clicks} over ${clicked.prompts} prompts) p50 ${clicked.p50} p95 ${clicked.p95} max ${clicked.max} ms, ` +
          `not loaded ${clicked.not_loaded}`,
      );
      perfRow({
        name: `chat_fast_scroll.fling_interval.n${size}`,
        p50: Number(flung.frame_p50 ?? 0),
        p95: Number(flung.frame_p95 ?? 0),
        target: NOMINAL_MS,
      });
      perfRow({ name: `chat_fast_scroll.fling_blank.n${size}`, p95: flung.blank_frames, unit: "frames" });
      perfRow({
        name: `chat_fast_scroll.rail_click_paint.n${size}`,
        p50: clicked.p50,
        p95: clicked.p95,
        target: TARGET_MS.response,
      });
      perfRow({ name: `chat_fast_scroll.rail_click_not_loaded.n${size}`, p95: clicked.not_loaded, unit: "clicks" });
      await context.close();
    } finally {
      await browser.close();
    }
  }
  console.log(`CHAT-FAST-SCROLL ${JSON.stringify(results)}`);
} finally {
  await vite.close();
}
