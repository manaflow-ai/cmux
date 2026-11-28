// l10n-allow-file: benchmark fixtures and output, not shipped UI.
// Typing in the markdown page (cmux-page://cmux.markdown/, markdown-page.html) in a long file, in a
// production build on Chromium: a keystroke's work must not grow with the document. The page is
// served as markdown-viewer-stress.bench.ts serves it, through a stand-in host that answers
// `cmux.markdown.config` with a generated file of prose with headings, ordered lists and tables,
// at 1,000 and 10,000 lines. Each size opens the page fresh, waits for its last line, and reads, in
// the page's own clock:
//   nodes     the document's DOM node count once the whole file shows;
//   keystroke from each keydown to the first painted frame (test/support/paintedFrames.ts) that
//             shows its character: 40 typed into a paragraph in the middle, then 40 into a table
//             cell in the middle, p50 and p95;
//   task      the longest main-thread task while typing (PerformanceObserver "longtask");
//   resize    the window narrowing 4 px a frame for 60 frames (the root element's width, written in
//             each frame's callback): each frame's main-thread work, from the write to the end of
//             that frame's rendering, p95.
//   bun bench/markdown-keystroke.bench.ts [rounds=1] [--dev]
// PROFILE=1 prints the 15 functions with the most self time while typing (an unminified build).
// TRACE=1 types TRACE_KEYS more under a Chromium trace and prints, per key: the main thread's time
// p95 (a light trace: tasks from one keydown to the next), and from a trace with invalidation
// tracking the elements restyled, the objects laid out, the area of the layout roots and the
// layout time, and the area painted.
/// <reference types="bun" />
import type { Browser, CDPSession, Page } from "playwright";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { chromium } from "./browsers";
import { traceWindow } from "./styleInvalidationTrace";
import { PERF_ROW_MARK, TARGET_MS, type PerfRow } from "./perfRow";
import {
  benchPositionals,
  buildLabel,
  gotoBenchPage,
  requireProductionReact,
  serveBenchPage,
} from "./support/benchPage";

const ROUNDS = Number(benchPositionals()[0] ?? 1);
const SIZES = (process.env.SIZES ?? "1000,10000").split(",").map(Number);
const KEYS = 40;
const RESIZE_FRAMES = 60;
/** Keystrokes traced (TRACE=1) for the renderer's work per key. */
const TRACE_KEYS = 40;
const TRACE = process.env.TRACE === "1";
const RESIZE_STEP_PX = 4;
const DEADLINE_MS = 120_000;
const PROFILE = process.env.PROFILE === "1";
const log = (...args: unknown[]) => console.error("markdown-keystroke:", ...args);

const TOP = "keystroke-top";
const BOTTOM = "keystroke-bottom";
/** The words the caret goes after: a paragraph and a table cell in the file's middle part. */
const PARAGRAPH = "middle-paragraph";
const CELL = "middle-cell";

/** About `lines` lines of prose: each part a heading, a paragraph, an ordered list and a table. */
function fixture(lines: number): string {
  const part = (i: number, middle: boolean) =>
    `## Section ${i}\n\n` +
    `Paragraph ${i} has **bold**, _emphasis_ and a [link](#section-${i})${middle ? ` ${PARAGRAPH}` : ""} in a ` +
    `sentence long enough to wrap once in a 72 character column.\n\n` +
    `1. first step ${i}\n2. second step ${i}\n3. third step ${i}\n\n` +
    `| name | kind | size |\n| --- | --- | ---: |\n| row ${i}${middle ? ` ${CELL}` : ""} | **bold** | ${i} |\n` +
    `| other ${i} | \`code\` | ${i * 2} |\n\n`;
  const per = part(0, false).split("\n").length - 1;
  const parts = Math.ceil(lines / per);
  const body = Array.from({ length: parts }, (_, i) => part(i, i === Math.floor(parts / 2))).join("");
  return `# ${TOP}\n\n${body}${BOTTOM}\n`;
}

/// The stand-in host (markdown-viewer-stress.bench.ts's, without its reload stream), before the
/// page's own code, and the longest task since `__mdBench.longest` was last reset.
function installHost(): void {
  type Envelope = { t: string; id?: number; op?: string; stream?: string };
  const bench = { longest: 0 };
  (window as unknown as { __mdBench: typeof bench }).__mdBench = bench;
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) bench.longest = Math.max(bench.longest, entry.duration);
  }).observe({ type: "longtask", buffered: true });
  let nextSub = 1;
  const postMessage = async (message: Envelope): Promise<unknown> => {
    if (message.t === "sub") return { t: "ok", id: message.id, value: { sub: nextSub++ } };
    if (message.t !== "call") return null;
    if (message.op === "cmux.markdown.config") {
      const text = await (await fetch("/__bench/fixture", { cache: "no-store" })).text();
      return { t: "ok", id: message.id, value: { path: "/bench/keystroke.md", text, hash: `h${text.length}` } };
    }
    return { t: "ok", id: message.id, value: {} };
  };
  (window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };
}

/** Resolves once the editor's last block holds `needle`. */
async function showing(page: Page, needle: string): Promise<void> {
  await page.waitForFunction(
    (needle) => !!document.querySelector(".md-prose")?.lastElementChild?.textContent?.includes(needle),
    needle,
    { timeout: DEADLINE_MS, polling: 100 },
  );
}

/** Puts the caret just after `needle` (scrolled into view) in the editor. */
async function caretAfter(page: Page, needle: string): Promise<void> {
  await page.evaluate((needle) => {
    const prose = document.querySelector<HTMLElement>(".md-prose")!;
    const walker = document.createTreeWalker(prose, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const at = node.textContent!.indexOf(needle);
      if (at < 0) continue;
      node.parentElement!.scrollIntoView({ block: "center" });
      prose.focus();
      const range = document.createRange();
      range.setStart(node, at + needle.length);
      range.collapse(true);
      getSelection()!.removeAllRanges();
      getSelection()!.addRange(range);
      return;
    }
    throw new Error(`no ${needle} in the document`);
  }, needle);
  // The editor reads the DOM selection on selectionchange: let it land.
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

/** Types `keys` characters at the caret; each one's keydown to the first painted frame that shows it. */
async function typeKeys(page: Page, keys = KEYS): Promise<number[]> {
  await page.evaluate(() => {
    const bench = window as unknown as { __keys: number[]; __keysHeard?: boolean };
    bench.__keys = [];
    if (bench.__keysHeard) return;
    bench.__keysHeard = true;
    // The text of the block holding the caret: one block, never the document.
    const blockText = () => {
      const node = getSelection()?.anchorNode;
      const element = node instanceof Element ? node : node?.parentElement;
      return element?.closest("p, td, th, li, h1, h2, h3, h4, h5, h6")?.textContent?.length ?? -1;
    };
    addEventListener(
      "keydown",
      (event) => {
        const start = event.timeStamp;
        const before = blockText();
        const out = bench.__keys;
        window.cmuxAfterPaint(() => {
          if (blockText() === before) return true;
          out.push(performance.now() - start);
          return false;
        });
      },
      { capture: true },
    );
  });
  for (let key = 0; key < keys; key++) {
    await page.keyboard.press(String.fromCharCode(97 + (key % 26)));
    await page.waitForFunction((count) => (window as unknown as { __keys: number[] }).__keys.length >= count, key + 1, {
      timeout: 10_000,
      polling: "raf",
    });
  }
  return page.evaluate(() => (window as unknown as { __keys: number[] }).__keys);
}

/** What one keystroke made the renderer do, from a Chromium trace: averaged per key, and each key's main-thread time. */
type KeyWork = {
  restyled: number;
  layoutObjects: number;
  layoutRootArea: number;
  layoutMs: number;
  paintArea: number;
  mainMs: number[];
};

/**
 * TRACE_KEYS keystrokes at the caret under a Chromium trace: the elements each style update
 * restyled (UpdateLayoutTree's element count), the objects each layout laid out (its dirty
 * objects), the area of its layout roots and its time, and the area each paint covered, per key;
 * and each key's main-thread time, its tasks from its keydown to the next key's.
 */
async function traceKeys(browser: Browser, page: Page): Promise<KeyWork> {
  type Ev = {
    name: string;
    ph: string;
    ts: number;
    tid: number;
    pid: number;
    dur?: number;
    args?: Record<string, any>;
  };
  const counted = (await traceWindow(browser, page, () => typeKeys(page, TRACE_KEYS))) as Ev[];
  // The main thread's time from a light trace: invalidation tracking slows the page several times.
  await browser.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] });
  await typeKeys(page, TRACE_KEYS);
  const timed = (JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: Ev[] }).traceEvents;
  const rendererMain = (events: Ev[]) => {
    const mains = new Set(
      events
        .filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain")
        .map((e) => `${e.pid}:${e.tid}`),
    );
    return events.filter((e) => mains.has(`${e.pid}:${e.tid}`)).sort((a, b) => a.ts - b.ts);
  };
  const main = rendererMain(counted);
  const light = rendererMain(timed);
  const area = (quad: unknown): number => {
    if (!Array.isArray(quad) || quad.length !== 8 || quad.some((v) => Math.abs(v) > 1e7)) return 0;
    const xs = [quad[0], quad[2], quad[4], quad[6]] as number[];
    const ys = [quad[1], quad[3], quad[5], quad[7]] as number[];
    return (Math.max(...xs) - Math.min(...xs)) * (Math.max(...ys) - Math.min(...ys));
  };
  let restyled = 0;
  let layoutObjects = 0;
  let layoutRootArea = 0;
  let layoutMs = 0;
  let paintArea = 0;
  for (const e of main) {
    if (e.name === "UpdateLayoutTree" && (e.ph === "X" || e.ph === "E"))
      restyled += Number(e.args?.elementCount ?? e.args?.data?.elementCount ?? 0);
    else if (e.name === "Layout" && e.ph === "X") {
      layoutObjects += Number(e.args?.beginData?.dirtyObjects ?? 0);
      layoutMs += (e.dur ?? 0) / 1000;
      layoutRootArea += area(e.args?.endData?.layoutRoots?.[0]?.quads?.[0]);
    } else if (e.name === "Paint" && e.ph === "X") paintArea += area(e.args?.data?.clip);
  }
  const keydowns = light.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "keydown").map((e) => e.ts);
  const mainMs = keydowns.map((start, index) => {
    const end = keydowns[index + 1] ?? Infinity;
    let busy = 0;
    for (const e of light)
      if (e.name === "RunTask" && e.ph === "X" && e.ts >= start && e.ts < end) busy += (e.dur ?? 0) / 1000;
    return busy;
  });
  const keys = Math.max(1, main.filter((e) => e.name === "EventDispatch" && e.args?.data?.type === "keydown").length);
  return {
    restyled: restyled / keys,
    layoutObjects: layoutObjects / keys,
    layoutRootArea: layoutRootArea / keys,
    layoutMs: layoutMs / keys,
    paintArea: paintArea / keys,
    mainMs,
  };
}

/** Each frame's main-thread work while the root narrows RESIZE_STEP_PX a frame. */
async function resize(page: Page): Promise<number[]> {
  return page.evaluate(
    ({ frames, step }) =>
      new Promise<number[]>((resolve) => {
        const root = document.documentElement;
        const start = root.clientWidth;
        const work: number[] = [];
        let written = 0;
        let count = 0;
        const stop = window.cmuxAfterPaint(
          () => {
            if (!written) return true;
            work.push(performance.now() - written);
            if (work.length < frames) return true;
            root.style.width = "";
            resolve(work);
            return false;
          },
          () => {
            if (count >= frames) return;
            count++;
            root.style.width = `${start - count * step}px`;
            written = performance.now();
          },
        );
        setTimeout(() => (stop(), resolve(work)), 30_000);
      }),
    { frames: RESIZE_FRAMES, step: RESIZE_STEP_PX },
  );
}

/// The profile so far: the 15 functions with the most self time, one line each.
async function topSelfTime(cdp: CDPSession): Promise<void> {
  type Node = { id: number; callFrame: { functionName: string; url: string; lineNumber: number } };
  const { profile } = (await cdp.send("Profiler.stop")) as unknown as {
    profile: { nodes: Node[]; samples: number[]; timeDeltas: number[] };
  };
  const self = new Map<number, number>();
  profile.samples.forEach((id, i) => self.set(id, (self.get(id) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000));
  const byName = new Map<string, number>();
  for (const node of profile.nodes) {
    const { functionName, url, lineNumber } = node.callFrame;
    const key = `${functionName || "(anonymous)"} ${url.replace(/^.*\//, "")}:${lineNumber + 1}`;
    byName.set(key, (byName.get(key) ?? 0) + (self.get(node.id) ?? 0));
  }
  for (const [key, ms] of [...byName].sort((a, b) => b[1] - a[1]).slice(0, 15))
    log(`  self ${ms.toFixed(0)} ms ${key}`);
}

type Result = { nodes: number[]; keys: number[]; longest: number[]; resize: number[]; traced: KeyWork[] };

async function runSize(browser: Browser, url: string, text: string, result: Result): Promise<void> {
  const context = await browser.newContext({ viewport: { width: 1200, height: 900 } });
  const page = await context.newPage();
  page.on("pageerror", (error) => log(`page error: ${error.message}`));
  try {
    await page.route("**/__bench/fixture", (route) =>
      route.fulfill({ status: 200, contentType: "text/markdown", body: text }),
    );
    await page.addInitScript(installHost);
    await installPaintedFrames(page);
    await page.goto(url);
    await showing(page, BOTTOM);
    result.nodes.push(
      await page.evaluate(() => {
        const walker = document.createTreeWalker(document, NodeFilter.SHOW_ALL);
        let count = 0;
        while (walker.nextNode()) count++;
        return count;
      }),
    );
    // Let the load's last tasks finish before typing is measured.
    await page.waitForTimeout(1_000);
    await page.evaluate(() => ((window as unknown as { __mdBench: { longest: number } }).__mdBench.longest = 0));
    const cdp = PROFILE ? await context.newCDPSession(page) : null;
    if (cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 500 });
      await cdp.send("Profiler.start");
    }
    await caretAfter(page, PARAGRAPH);
    result.keys.push(...(await typeKeys(page)));
    await caretAfter(page, CELL);
    result.keys.push(...(await typeKeys(page)));
    if (cdp) await topSelfTime(cdp);
    result.longest.push(
      await page.evaluate(() => (window as unknown as { __mdBench: { longest: number } }).__mdBench.longest),
    );
    if (TRACE) {
      await caretAfter(page, PARAGRAPH);
      result.traced.push(await traceKeys(browser, page));
    }
    result.resize.push(...(await resize(page)));
  } finally {
    await context.close().catch(() => {});
  }
}

const quantile = (values: readonly number[], q: number): number => {
  if (!values.length) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};
const fmt = (value: number) => (Number.isFinite(value) ? value.toFixed(1) : "-");

const served = await serveBenchPage("/markdown-page.html", { unminified: PROFILE });
const browser = await chromium.launch({ headless: true });
const results = new Map<number, Result>();
try {
  {
    // The build check: a dev bundle's numbers are refused unless --dev labelled them.
    const probe = await browser.newPage();
    await probe.addInitScript(installHost);
    await probe.route("**/__bench/fixture", (route) => route.fulfill({ status: 200, body: fixture(20) }));
    await gotoBenchPage(probe, served);
    await showing(probe, BOTTOM);
    await requireProductionReact(probe, served);
    await probe.close();
  }
  for (const lines of SIZES) {
    const text = fixture(lines);
    const result: Result = { nodes: [], keys: [], longest: [], resize: [], traced: [] };
    results.set(lines, result);
    for (let round = 0; round < ROUNDS; round++) await runSize(browser, served.url, text, result);
    log(
      `${lines} lines: dom nodes ${Math.max(...result.nodes)}, keystroke p50 ${fmt(quantile(result.keys, 0.5))} ` +
        `p95 ${fmt(quantile(result.keys, 0.95))} ms (${result.keys.length} keys), longest task while typing ` +
        `${fmt(Math.max(0, ...result.longest))} ms, resize frame p95 ${fmt(quantile(result.resize, 0.95))} ms`,
    );
    for (const traced of result.traced)
      log(
        `${lines} lines per key (traced): main thread p95 ${fmt(quantile(traced.mainMs, 0.95))} ms, restyled ` +
          `${fmt(traced.restyled)} elements, layout ${fmt(traced.layoutObjects)} objects over ` +
          `${fmt(traced.layoutRootArea / 1e3)}k px² of roots in ${fmt(traced.layoutMs)} ms, paint ` +
          `${fmt(traced.paintArea / 1e3)}k px²`,
      );
    const row: PerfRow = {
      name: `markdown_viewer.keystroke.l${lines}`,
      p50: quantile(result.keys, 0.5),
      p95: quantile(result.keys, 0.95),
      target: TARGET_MS.response,
    };
    console.log(PERF_ROW_MARK + JSON.stringify(row));
  }
} finally {
  await browser.close();
  await served.close();
}
log(`build ${buildLabel(served)}`);
process.exit(0);
