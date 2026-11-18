// l10n-allow-file: bench output labels, not shipped UI.
// Whether a TranscriptView render costs O(window) or O(rows in the model).
//
// The scroll lane measured a 100k-row fling: a page commit renders only the 49-60 window rows, the
// fling's other commits a median of 6 rows, yet a page commit cost 131 ms and the fling 10.4 s of
// long frames. So the cost is TranscriptView's own work over the model, not its rows. This bench
// mounts the transcript (test/browser/transcript-fling.html, the pane's VirtualTranscript with the
// app's incremental shaping) at each size in SIZES, drives the same scripted input at each, and
// prints, per phase, how long TranscriptView's own code ran per TranscriptView render:
//   step     the view moved up one viewport a frame, STEPS frames (each frame a window change)
//   fling    the debug fling (debug.ts startFling, bottom to top in FLING_S seconds, a step a frame)
//   prepend  PREPENDS commits that put one older row above the first and take it away again, the
//            shape of an older page landing (every index shifts)
// Two passes per size, each on a fresh page, because block coverage slows the code it counts:
//   profile   Chromium's sampling profile (CDP Profiler, 50 µs). A sample is TranscriptView's when its
//             stack has a frame in VirtualTranscript.tsx from `VirtualTranscript` down (the wrapper,
//             TranscriptView's body, and every closure it defines: memos, effects, handlers). It is
//             filed under the first source frame below the TranscriptView body (the pass), named by
//             its source file and line through the build's source maps.
//   coverage  V8 precise block coverage over the same phases: how many times each block of the
//             pane's source ran. A block whose count per TranscriptView render grows with the model is
//             an O(rows) pass, and the count is deterministic, which a time is not.
// Renders are counted off each commit through React's DevTools hook (PerformedWork on the fiber),
// in the production build: TranscriptView renders, RowFrame renders, commits.
//
//   bun bench/transcript-render-scale.bench.ts [sizes=10000,100000] [top=30]
//   stream   STREAMS updates of the reply above the live line, one a frame, at the latest row (a
//            streamed token: a new rows array whose only new object is near the tail)
//   STEPS=60 FLING_S=3 PREPENDS=6 STREAMS=60 PASSES=profile,coverage
// Prints one table per pass: each pass's ms (or block count) per TranscriptView render at each size,
// and the ratio of the largest size to the smallest (10x rows: ~10 means O(rows), ~1 means O(window)).
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import type { CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import {
  benchPositionals,
  buildLabel,
  gotoBenchPage,
  requireProductionReact,
  serveBenchPage,
} from "./support/benchPage";
import { sourceMapper } from "./sourceMapper";

const args = benchPositionals();
const SIZES = (args[0] ?? "10000,100000").split(",").map(Number);
const TOP = Number(args[1] ?? 30);
const STEPS = Number(process.env.STEPS ?? 60);
const FLING_S = Number(process.env.FLING_S ?? 3);
const PREPENDS = Number(process.env.PREPENDS ?? 6);
const STREAMS = Number(process.env.STREAMS ?? 60);
const PASSES = (process.env.PASSES ?? "profile,coverage").split(",");
if (SIZES.some((n) => !Number.isInteger(n) || n < 3) || SIZES.length < 1)
  throw new Error("usage: transcript-render-scale.bench.ts [sizes=10000,100000] [top]");
const PHASES = ["step", "fling", "prepend", "stream"] as const;
type Phase = (typeof PHASES)[number];

const FILE = "src/agent-session/acpmux/VirtualTranscript.tsx";
/// Where TranscriptView's code starts in FILE: `export function VirtualTranscript`, the wrapper that
/// compares its props and renders the memoized TranscriptView. Read off the source so a moved line
/// does not quietly file the wrapper's work elsewhere.
const source = fs.readFileSync(path.join(import.meta.dir, "..", FILE), "utf8").split("\n");
const VIEW_FROM = source.findIndex((line) => line.startsWith("export function VirtualTranscript(")) + 1;
const VIEW_BODY = source.findIndex((line) => line.startsWith("function TranscriptView(")) + 1;
if (VIEW_FROM < 1 || VIEW_BODY < 1) throw new Error(`transcript-render-scale: ${FILE} no longer has its markers`);

type Counts = { commits: number; view: number; rows: number };

/// Counts TranscriptView and RowFrame renders per commit, as React DevTools reads a render
/// (PerformedWork on a fiber the commit visited). Installed before React loads.
function defineRenderCount() {
  const state = { on: false, commits: 0, view: 0, rows: 0 };
  (window as unknown as { __renderCount: typeof state }).__renderCount = state;
  const COMPONENT = new Set([0, 1, 11, 14, 15]);
  type Fiber = {
    tag: number;
    type: any;
    flags: number;
    child: Fiber | null;
    sibling: Fiber | null;
    alternate: Fiber | null;
  };
  const nameOf = (fiber: Fiber) => {
    const type = fiber.type;
    return type?.displayName || type?.name || type?.render?.name || type?.type?.name || "";
  };
  const count = (fiber: Fiber) => {
    const name = nameOf(fiber);
    if (name === "TranscriptView") state.view += 1;
    else if (name === "RowFrame") state.rows += 1;
  };
  const mounted = (fiber: Fiber) => {
    for (let at: Fiber | null = fiber; at; at = at.sibling) {
      if (COMPONENT.has(at.tag)) count(at);
      if (at.child) mounted(at.child);
    }
  };
  const updated = (next: Fiber, prev: Fiber) => {
    if (COMPONENT.has(next.tag) && (next.flags & 1) === 1) count(next);
    if (next.child === prev.child) return;
    for (let child = next.child; child; child = child.sibling) {
      if (child.alternate) updated(child, child.alternate);
      else {
        if (COMPONENT.has(child.tag)) count(child);
        if (child.child) mounted(child.child);
      }
    }
  };
  const hook = (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ ?? {
    renderers: new Map(),
    supportsFiber: true,
    inject(renderer: unknown) {
      hook.renderers.set(hook.renderers.size + 1, renderer);
      return hook.renderers.size;
    },
    onScheduleFiberRoot() {},
    onCommitFiberUnmount() {},
    onPostCommitFiberRoot() {},
    checkDCE() {},
  };
  const previous = hook.onCommitFiberRoot;
  hook.onCommitFiberRoot = (id: number, root: { current: Fiber }, ...rest: unknown[]) => {
    if (state.on) {
      state.commits += 1;
      const current = root.current;
      if (current.alternate) updated(current, current.alternate);
      else if (current.child) mounted(current.child);
    }
    return previous?.call(hook, id, root, ...rest);
  };
  (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ = hook;
}

const startCount = (page: Page) =>
  page.evaluate(() => {
    const state = (window as unknown as { __renderCount: Counts & { on: boolean } }).__renderCount;
    Object.assign(state, { on: true, commits: 0, view: 0, rows: 0 });
  });
const stopCount = (page: Page): Promise<Counts> =>
  page.evaluate(() => {
    const state = (window as unknown as { __renderCount: Counts & { on: boolean } }).__renderCount;
    state.on = false;
    return { commits: state.commits, view: state.view, rows: state.rows };
  });

const frames = (page: Page, count: number) =>
  page.evaluate(async (n) => {
    for (let frame = 0; frame < n; frame += 1) await new Promise(requestAnimationFrame);
  }, count);

/// Seeds `rows` rows (app shaping), settles at the latest row.
async function mount(page: Page, rows: number) {
  await page.waitForFunction(() => "__shaping" in window && "__debug" in window);
  await page.evaluate(() => (window as unknown as { __shaping: (m: string) => void }).__shaping("app"));
  const seeded = await page.evaluate(`window.__debug.seedRows(${rows})`);
  await page.evaluate(async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    scroller.scrollTop = scroller.scrollHeight;
    for (let frame = 0; frame < 60; frame += 1) await new Promise(requestAnimationFrame);
  });
  return seeded;
}

/// One phase's input. Every phase starts from the latest row, settled.
async function drive(page: Page, phase: Phase) {
  await page.evaluate(async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    scroller.scrollTop = scroller.scrollHeight;
    for (let frame = 0; frame < 30; frame += 1) await new Promise(requestAnimationFrame);
  });
  await frames(page, 10);
  if (phase === "step")
    await page.evaluate(async (steps) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let step = 0; step < steps; step += 1) {
        scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight);
        await new Promise(requestAnimationFrame);
      }
      for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
    }, STEPS);
  else if (phase === "fling")
    await page.evaluate(async (seconds) => {
      const debug = (
        window as unknown as {
          __debug: { startFling(s: number, o: object): Promise<unknown> };
        }
      ).__debug;
      await debug.startFling(seconds, { wait: true, nominal_ms: 1000 / 60 });
      for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
    }, FLING_S);
  else if (phase === "stream")
    await page.evaluate(async (count) => {
      const step = (window as unknown as { __stepFoldStream: () => void }).__stepFoldStream;
      for (let at = 0; at < count; at += 1) {
        step();
        await new Promise(requestAnimationFrame);
      }
      for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
    }, STREAMS);
  else
    await page.evaluate(async (count) => {
      const show = (window as unknown as { __showOlder: (shown: boolean) => void }).__showOlder;
      for (let at = 0; at < count; at += 1) {
        show(at % 2 === 0);
        for (let frame = 0; frame < 6; frame += 1) await new Promise(requestAnimationFrame);
      }
      show(false);
      for (let frame = 0; frame < 6; frame += 1) await new Promise(requestAnimationFrame);
    }, PREPENDS);
}

type Frame = {
  functionName: string;
  url: string;
  lineNumber: number;
  columnNumber: number;
};
type Profile = {
  nodes: Array<{
    id: number;
    callFrame: Frame;
    children?: number[];
    positionTicks?: { line: number; ticks: number }[];
  }>;
  samples: number[];
  timeDeltas: number[];
};

/// Bundle position to `file:line` through the build's source maps.
function mapperFor(outDir: string) {
  const mapped = sourceMapper(outDir);
  const files = new Map<string, string | undefined>();
  // A chunk's URL is page-relative (test/browser/chunks/x.mjs); the map sits beside the emitted chunk.
  const locate = (url: string) => {
    if (!files.has(url)) {
      const base = url.replace(/^https?:\/\/[^/]+\//, "").replace(/\?.*$/, "");
      const parts = base.split("/");
      let found: string | undefined;
      for (let drop = 0; drop < parts.length && !found; drop += 1) {
        const tail = parts.slice(drop).join("/");
        if (fs.existsSync(path.join(outDir, `${tail}.map`))) found = tail;
      }
      files.set(url, found);
    }
    return files.get(url);
  };
  return (url: string, line: number, column: number) => {
    const file = locate(url);
    if (!file) return undefined;
    // sourceMapper looks in `<dir>/assets/<file>.map`; the chunk's map is `<outDir>/<file>.map`.
    // The map's sources are relative to the chunk and climb out of the build directory to the tree.
    const where = mapped(path.join("..", file), line, column).replace(/^.*?\/webviews\//, "");
    return where.startsWith("..") || where.includes(".mjs:") ? undefined : where;
  };
}

/// React's work-loop and commit entries: below the innermost one, a stack is whatever React is
/// rendering or committing now, whoever called flushSync above it.
const REACT_ENTRIES = new Set([
  "performWorkOnRoot",
  "performSyncWorkOnRoot",
  "flushSyncWorkAcrossRoots_impl",
  "flushSyncWorkOnAllRoots",
  "renderRootSync",
  "renderRootConcurrent",
  "commitRoot",
  "commitRootImpl",
  "flushPassiveEffects",
  "flushSpawnedWork",
  "flushLayoutEffects",
  "flushMutationEffects",
]);

const lineOf = (where: string | undefined) => Number(where?.split(":").at(-1));
const inView = (where: string | undefined) => where?.startsWith(FILE + ":") === true && lineOf(where) >= VIEW_FROM;
const isSource = (where: string | undefined) => where?.startsWith("src/") === true;

type ProfileResult = {
  counts: Counts;
  viewMs: number;
  bodyMs: number;
  /// React work a TranscriptView handler or effect flushed synchronously that is not TranscriptView's
  /// own (row renders, the minimap, DOM commit): reported beside it, not in it.
  triggeredMs: number;
  renders: number[];
  /// ms by pass: the first source frame below the TranscriptView body, or an effect or handler.
  passes: Map<string, number>;
  /// ms by the innermost source function under TranscriptView, whatever pass called it.
  leaves: Map<string, number>;
  /// Triggered ms by component and innermost source function (rows, the minimap: O(window) or not).
  triggers: Map<string, number>;
};

function readProfile(profile: Profile, map: ReturnType<typeof mapperFor>, counts: Counts): ProfileResult {
  const parent = new Map<number, number>();
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const where = new Map<number, string | undefined>();
  for (const node of profile.nodes) {
    const frame = node.callFrame;
    where.set(node.id, frame.url ? map(frame.url, frame.lineNumber, frame.columnNumber) : undefined);
  }
  const label = (id: number) => {
    const node = byId.get(id)!;
    return `${node.callFrame.functionName || "(anonymous)"} ${where.get(id)}`;
  };
  // Each sample: is it TranscriptView's, is it inside the body (render) or not, and which pass.
  const verdict = new Map<
    number,
    {
      view: boolean;
      body: boolean;
      triggered?: boolean;
      pass?: string;
      leaf?: string;
    }
  >();
  const judge = (leaf: number) => {
    const known = verdict.get(leaf);
    if (known) return known;
    const stack: number[] = [];
    for (let at: number | undefined = leaf; at !== undefined; at = parent.get(at)) stack.unshift(at);
    // A handler of TranscriptView's that flushes (flushSync in pacedScroll and handleScroll) runs a
    // whole React render and commit under it: the rows, the minimap, the DOM. Only what is below the
    // innermost React entry decides whose a sample is: TranscriptView's body or a closure of its
    // (an effect, a nested handler) there, else the work it triggered (`triggered`).
    let entry = -1;
    stack.forEach((id, at) => {
      if (REACT_ENTRIES.has(byId.get(id)!.callFrame.functionName)) entry = at;
    });
    const isBody = (id: number) => byId.get(id)!.callFrame.functionName === "TranscriptView";
    const outer = stack.findIndex((id, at) => at > entry && (inView(where.get(id)) || isBody(id)));
    let result: {
      view: boolean;
      body: boolean;
      triggered?: boolean;
      pass?: string;
      leaf?: string;
    } = {
      view: false,
      body: false,
      triggered: entry >= 0 && stack.slice(0, entry).some((id) => inView(where.get(id))),
    };
    if (outer >= 0) {
      const top = stack[outer]!;
      const body = stack.findIndex((id, at) => at > entry && isBody(id));
      // The pass: inside the body, the first source frame below it (a memo, a helper); outside the
      // body (an effect, a handler, the wrapper), the outermost frame and the first source frame below.
      if (body >= 0) {
        const below = stack.slice(body + 1).find((id) => isSource(where.get(id)));
        const leafNode = byId.get(leaf)!;
        result = {
          view: true,
          body: true,
          pass:
            below !== undefined
              ? label(below)
              : leaf === stack[body]
                ? `TranscriptView self`
                : `TranscriptView > ${leafNode.callFrame.functionName || "(native)"}`,
        };
      } else {
        const below = stack.slice(outer + 1).find((id) => isSource(where.get(id)));
        result = {
          view: true,
          body: false,
          pass: below !== undefined ? `${label(top)} > ${label(below)}` : label(top),
        };
      }
    }
    // The innermost source function: where inside a pass the time went (a loop's own helper).
    if (result.view || result.triggered) {
      const inner = [...stack].reverse().find((id) => isSource(where.get(id)));
      result.leaf = inner === undefined ? "(no source frame)" : label(inner);
    }
    // Triggered work: the component (first source frame under the React entry) and its leaf.
    if (!result.view && result.triggered) {
      const component = stack.slice(entry + 1).find((id) => isSource(where.get(id)));
      result.pass = `${component === undefined ? "(react/DOM)" : label(component)} :: ${result.leaf}`;
    }
    verdict.set(leaf, result);
    return result;
  };
  const passes = new Map<string, number>();
  const leaves = new Map<string, number>();
  const triggers = new Map<string, number>();
  let viewMs = 0;
  let bodyMs = 0;
  let triggeredMs = 0;
  // One render of the body: a run of consecutive samples inside it.
  const renders: number[] = [];
  let run = 0;
  for (let index = 0; index < profile.samples.length; index += 1) {
    const ms = (profile.timeDeltas[index + 1] ?? 0) / 1000;
    const judged = judge(profile.samples[index]!);
    if (judged.body) run += ms;
    else if (run > 0) {
      renders.push(run);
      run = 0;
    }
    if (judged.triggered && !judged.view) {
      triggeredMs += ms;
      triggers.set(judged.pass!, (triggers.get(judged.pass!) ?? 0) + ms);
    }
    if (!judged.view) continue;
    viewMs += ms;
    if (judged.body) bodyMs += ms;
    passes.set(judged.pass!, (passes.get(judged.pass!) ?? 0) + ms);
    leaves.set(judged.leaf!, (leaves.get(judged.leaf!) ?? 0) + ms);
  }
  if (run > 0) renders.push(run);
  // TranscriptView's own lines, where its self time landed (positionTicks are bundle lines).
  const bodies = profile.nodes.filter((node) => node.callFrame.functionName === "TranscriptView");
  const total = bodies.reduce(
    (sum, node) => sum + (node.positionTicks ?? []).reduce((all, tick) => all + tick.ticks, 0),
    0,
  );
  const selfMs = passes.get("TranscriptView self") ?? 0;
  for (const node of bodies) {
    for (const tick of node.positionTicks ?? []) {
      const at = map(node.callFrame.url, tick.line - 1, 0);
      const key = `TranscriptView self @ ${at}`;
      passes.set(key, (passes.get(key) ?? 0) + (selfMs * tick.ticks) / Math.max(1, total));
    }
  }
  if (total > 0) passes.delete("TranscriptView self");
  return {
    counts,
    viewMs,
    bodyMs,
    triggeredMs,
    renders,
    passes,
    leaves,
    triggers,
  };
}

type CoverageResult = { counts: Counts; blocks: Map<string, number> };

async function readCoverage(cdp: CDPSession, outDir: string, map: ReturnType<typeof mapperFor>, counts: Counts) {
  const { result } = (await cdp.send("Profiler.takePreciseCoverage")) as unknown as {
    result: Array<{
      url: string;
      functions: Array<{
        functionName: string;
        ranges: Array<{
          startOffset: number;
          endOffset: number;
          count: number;
        }>;
      }>;
    }>;
  };
  const blocks = new Map<string, number>();
  for (const script of result) {
    if (!script.url.startsWith("http")) continue;
    const base = script.url.replace(/^https?:\/\/[^/]+\//, "").replace(/\?.*$/, "");
    const parts = base.split("/");
    let file: string | undefined;
    for (let drop = 0; drop < parts.length && !file; drop += 1) {
      const tail = parts.slice(drop).join("/");
      if (fs.existsSync(path.join(outDir, tail))) file = tail;
    }
    if (!file) continue;
    const text = fs.readFileSync(path.join(outDir, file), "utf8");
    const starts = [0];
    for (let at = 0; at < text.length; at += 1) if (text.charCodeAt(at) === 10) starts.push(at + 1);
    const position = (offset: number) => {
      let lo = 0;
      let hi = starts.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (starts[mid]! <= offset) lo = mid;
        else hi = mid - 1;
      }
      return { line: lo, column: offset - starts[lo]! };
    };
    for (const fn of script.functions)
      for (const range of fn.ranges) {
        if (range.count === 0) continue;
        const { line, column } = position(range.startOffset);
        const at = map(script.url, line, column);
        if (!isSource(at)) continue;
        const key = `${at} (${fn.functionName || "anonymous"})`;
        // A block's count is its own executions; the function's first range counts its calls.
        blocks.set(key, Math.max(blocks.get(key) ?? 0, range.count));
      }
  }
  return { counts, blocks } satisfies CoverageResult;
}

const served = await serveBenchPage("/test/browser/transcript-fling.html", {
  unminified: true,
  sourcemap: true,
});
if (!served.outDir)
  throw new Error("transcript-render-scale: needs a build (no --dev): it reads the build's source maps");
const map = mapperFor(served.outDir);
const browser = await chromium.launch({ headless: true });
const profiles = new Map<string, ProfileResult>();
const coverages = new Map<string, CoverageResult>();
try {
  for (const size of SIZES)
    for (const pass of PASSES) {
      const page = await browser.newPage({
        viewport: { width: 900, height: 900 },
      });
      await page.addInitScript(defineRenderCount);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Profiler.enable");
      // Block coverage counts only code compiled after it starts: before the page's scripts.
      if (pass === "coverage")
        await cdp.send("Profiler.startPreciseCoverage", {
          callCount: true,
          detailed: true,
        });
      await gotoBenchPage(page, served);
      await requireProductionReact(page, { dev: served.dev });
      const seeded = await mount(page, size);
      console.log(
        `transcript-render-scale build=${buildLabel(served)} pass=${pass} size=${size} fixture=${JSON.stringify(seeded)}`,
      );
      for (const phase of PHASES) {
        if (pass === "coverage") await cdp.send("Profiler.takePreciseCoverage"); // resets the counts
        else {
          await cdp.send("Profiler.setSamplingInterval", { interval: 50 });
          await cdp.send("Profiler.start");
        }
        await startCount(page);
        await drive(page, phase);
        const counts = await stopCount(page);
        const key = `${size}/${phase}`;
        if (pass === "coverage") coverages.set(key, await readCoverage(cdp, served.outDir, map, counts));
        else {
          const { profile } = (await cdp.send("Profiler.stop")) as unknown as {
            profile: Profile;
          };
          const read = readProfile(profile, map, counts);
          profiles.set(key, read);
          const sorted = [...read.renders].sort((a, b) => a - b);
          const q = (p: number) => (sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] ?? 0).toFixed(2);
          console.log(
            `  ${phase}: commits=${counts.commits} TranscriptView renders=${counts.view} RowFrame renders=${counts.rows}` +
              ` view_ms=${read.viewMs.toFixed(1)} (body ${read.bodyMs.toFixed(1)}, outside body ${(read.viewMs - read.bodyMs).toFixed(1)})` +
              ` triggered_ms=${read.triggeredMs.toFixed(1)}` +
              ` per_render_ms=${(read.viewMs / Math.max(1, counts.view)).toFixed(2)}` +
              ` body_run_ms p50/p95/max=${q(0.5)}/${q(0.95)}/${q(1)}`,
          );
        }
      }
      if (pass === "coverage") await cdp.send("Profiler.stopPreciseCoverage");
      await page.close();
    }

  const small = SIZES[0]!;
  const large = SIZES.at(-1)!;
  const fmt = (value: number | undefined, digits = 2) => (value === undefined ? "-" : value.toFixed(digits));
  for (const phase of PHASES) {
    if (PASSES.includes("profile"))
      for (const by of ["passes", "leaves", "triggers"] as const) {
        console.log(
          `\n### profile ${by}, ${phase}: ms per TranscriptView render (lane-VM, Chromium, production unminified)\n`,
        );
        console.log(`| pass | ${SIZES.map((n) => `${n}`).join(" | ")} | ratio |`);
        console.log(`|---|${SIZES.map(() => "---").join("|")}|---|`);
        const per = (n: number) => {
          const read = profiles.get(`${n}/${phase}`)!;
          return new Map([...read[by]].map(([k, ms]) => [k, ms / Math.max(1, read.counts.view)]));
        };
        const tables = SIZES.map(per);
        const keys = [...new Set(tables.flatMap((t) => [...t.keys()]))].sort(
          (a, b) => (tables.at(-1)!.get(b) ?? 0) - (tables.at(-1)!.get(a) ?? 0),
        );
        const total = (n: number) => {
          const read = profiles.get(`${n}/${phase}`)!;
          return (by === "triggers" ? read.triggeredMs : read.viewMs) / Math.max(1, read.counts.view);
        };
        console.log(
          `| **total** | ${SIZES.map((n) => fmt(total(n))).join(" | ")} | ${fmt(total(large) / total(small), 1)} |`,
        );
        for (const key of keys.slice(0, TOP)) {
          const values = tables.map((t) => t.get(key));
          const ratio = (values.at(-1) ?? 0) / Math.max(1e-6, values[0] ?? 0);
          console.log(`| ${key} | ${values.map((v) => fmt(v, 3)).join(" | ")} | ${fmt(ratio, 1)} |`);
        }
      }
    if (PASSES.includes("coverage")) {
      console.log(`\n### coverage, ${phase}: block executions per TranscriptView render, largest at ${large}\n`);
      console.log(`| block | ${SIZES.map((n) => `${n}`).join(" | ")} | ratio |`);
      console.log(`|---|${SIZES.map(() => "---").join("|")}|---|`);
      const per = (n: number) => {
        const read = coverages.get(`${n}/${phase}`)!;
        return new Map([...read.blocks].map(([k, c]) => [k, c / Math.max(1, read.counts.view)]));
      };
      const tables = SIZES.map(per);
      const keys = [...tables.at(-1)!.keys()].sort((a, b) => tables.at(-1)!.get(b)! - tables.at(-1)!.get(a)!);
      for (const key of keys.slice(0, TOP)) {
        const values = tables.map((t) => t.get(key));
        const ratio = (values.at(-1) ?? 0) / Math.max(1e-6, values[0] ?? 0);
        console.log(`| ${key} | ${values.map((v) => fmt(v, 0)).join(" | ")} | ${fmt(ratio, 1)} |`);
      }
      const counts = SIZES.map((n) => coverages.get(`${n}/${phase}`)!.counts);
      console.log(
        `renders: ${SIZES.map((n, i) => `${n}: commits=${counts[i]!.commits} view=${counts[i]!.view} rows=${counts[i]!.rows}`).join("; ")}`,
      );
    }
  }
} finally {
  await browser.close();
  await served.close();
}
