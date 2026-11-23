// l10n-allow-file: benchmark output, not shipped UI.
// The floor of a chat's cold start (Leo, 2026-11-22, ask-4f598a3082: "theoretically, it's all just text. and
// theoretically, we have a lot of hidden text. so it should be able to be as fast as the terminal, or at least get
// close. if not, we need to figure out/map out all the possible ways why not, and then fix them."). One long real
// transcript (test/fixtures/chat-sim/replay-lane-session.ndjson, a sanitized acpmux session of 3561 records, 2.5 MB)
// is opened cold, in a fresh browser context each round (no HTTP or compiled-code cache), three ways:
//   bare       the floor: a page with no framework that asks the same stand-in acpmux for the same attach page,
//              decodes it, folds its records into rows of text (every text the records carry, the hidden ones too)
//              and writes them into one scroller, scrolled to its end;
//   pane       the production pane (a vite build of its dev entry, served as the app serves it: one linked pane.css,
//              the snapshot boot script before the module, as first-load-after-restart.bench.ts does) with no copy
//              kept: what a restart with no snapshot, a first open or a chat whose copy did not fit costs;
//   pane-copy  the same pane served the copy a warm load of the same chat wrote (chatSnapshot/capture.ts): the
//              snapshot the host keeps per chat and the boot script paints before the bundle runs.
// Per round, from navigation start (performance.now()):
//   first      the frame that first painted the newest answer's text (copy or live page), read after it painted;
//   live       the frame that first painted it from the live page (the copy gone or never drawn);
//   fcp        the browser's first-contentful-paint.
// Then TRACE_ROUNDS traced loads per mode (a Chrome trace with the sampling profiler at 100 us) split the main
// thread's time from navigation to the first paint, and from there to the live paint, into stages:
//   boot       fetching, compiling and running the page's scripts before any of its own work (v8 compile and
//              evaluate events with no app frame under them);
//   decode     JSON.parse anywhere (the attach page, the host's answers, localStorage reads);
//   rehydrate  folding records into the chat's state: the transport, the store and the turn model (REHYDRATE below);
//   markdown   the markdown parse and render, syntax highlighting (MARKDOWN below);
//   mount      React rendering and committing the rows (react-dom and the components' own render code);
//   layout     style recalculation and layout (UpdateLayoutTree, Layout, ParseAuthorStyleSheet);
//   paint      pre-paint, paint and layerize;
//   other      every other sample of the page's own scripts, GC and the browser's own work on the main thread;
//   wait       the rest of the wall time: the main thread idle (a socket, a fetch, a timer).
// Hidden text: after the live paint, the characters of text the live root holds, and how many of them sit in an
// element that is in view and drawn (the rest is text the pane mounted that nobody sees).
//   [ROUNDS=5] [TRACE_ROUNDS=2] [MODES=bare,pane,pane-copy] [REPEAT=1] [CPU=1] [TOP=0] [PANE_SOURCE_REF=sha]
//     bun bench/chat-floor.bench.ts
// REPEAT=N plays the session's turns N times over (seq renumbered), for a longer chat. CPU=N slows each page's CPU
// N times. TOP=N prints each stage's N busiest source files. PANE_SOURCE_REF=<sha> builds the pane's sources under
// src/agent-session and src/ui at that revision, the same harness, for a before/after. One `CHAT_FLOOR_JSON {...}`
// line carries every number; PERF_ROW lines name chat_floor.<mode>.first and chat_floor.<mode>.live.
/// <reference types="bun" />
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import type { Browser, CDPSession } from "playwright";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { perfRow } from "./perfRow";
import { sourceMapper } from "./sourceMapper";
import {
  PAGE_STYLE_ID,
  SNAPSHOT_BOOT_GLOBAL,
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_THEME_GLOBAL,
  type ChatSnapshot,
} from "../src/agent-session/acpmux/chatSnapshot/shared";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { snapshotCss } from "../scripts/agent-pane/snapshotCss.mjs";

const MODES_KNOWN = ["bare", "pane", "pane-copy"] as const;
type Mode = (typeof MODES_KNOWN)[number];
const MODES = (process.env.MODES ?? MODES_KNOWN.join(",")).split(",").filter(Boolean) as Mode[];
for (const mode of MODES) if (!MODES_KNOWN.includes(mode)) throw new Error(`MODES must name ${MODES_KNOWN.join(", ")}`);
const ROUNDS = Number(process.env.ROUNDS ?? 5);
const TRACE_ROUNDS = Number(process.env.TRACE_ROUNDS ?? 2);
const REPEAT = Number(process.env.REPEAT ?? 1);
const CPU = Number(process.env.CPU ?? 1);
const TOP = Number(process.env.TOP ?? 0);
for (const [name, value] of [
  ["ROUNDS", ROUNDS],
  ["TRACE_ROUNDS", TRACE_ROUNDS],
  ["REPEAT", REPEAT],
  ["CPU", CPU],
  ["TOP", TOP],
] as const)
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} must be a whole number`);
const VIEWPORT = { width: 1200, height: 800 };
/// The theme key the copy is written under and the page is told it has now (shared.ts `misfit`).
const THEME = "bench-theme";
const webviews = path.resolve(import.meta.dir, "..");
const chatSnapshotSource = path.join(webviews, "src/agent-session/acpmux/chatSnapshot");
const FIXTURE_FILE = path.join(webviews, "test/fixtures/chat-sim/replay-lane-session.ndjson");

// ---- The chat: the recorded session, REPEAT times over.
const recorded = fs
  .readFileSync(FIXTURE_FILE, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line) as EventRecord);
const SESSION_ID = recorded[0]!.sessionId;
const events: EventRecord[] = [];
for (let pass = 0; pass < Math.max(1, REPEAT); pass++)
  for (const record of recorded) events.push({ ...record, seq: events.length + 1 });
const turnCount = events.filter((event) => event.kind === "user_message").length;
const session = {
  sessionId: SESSION_ID,
  cwd: "/home/dev/cmux",
  title: "Floor bench",
  harness: "claude",
  family: "claude",
  status: "ready",
  turnCount,
  updatedAt: events.at(-1)!.at,
  lastSeq: events.length,
};
/// TARGET=text: a text the first painted rows must hold too (unset: any drawn row of the chat counts). The recorded
/// session's open page (128 KiB, direct.ts OPEN_PAGE_BYTES) is its newest 105 records: tool calls and a subagent's
/// work, no top-level answer, so the default is the rows, as chat-open.bench.ts's first_row is.
const LATEST = process.env.TARGET ?? "";

// ---- The stand-in acpmux (chat-open.bench.ts's): one session, its newest page on attach.
const newest = (limit: number, beforeSeq = Infinity, maxBytes?: unknown) =>
  newestPage(events, { limit, beforeSeq, maxBytes });
/// The pane's own attach asks, so the bare page reads the same page.
let paneAttach: Record<string, unknown> = { limit: 400, maxBytes: 128 * 1024 };
let attachBytes = 0;
let attachRecords = 0;
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach": {
      if (params.bare !== true) paneAttach = params;
      const asked = params.bare === true ? paneAttach : params;
      const { page, hasMore } = newest(Number(asked.limit ?? 400), Infinity, asked.maxBytes);
      const result = { session, lastSeq: events.at(-1)!.seq, events: page, hasMore };
      attachRecords = page.length;
      return result;
    }
    case "_acpmux/events": {
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
        return { events: prompts, hasMore: false, lastSeq: events.at(-1)!.seq };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newest(Number(params.limit ?? 400), Number(params.beforeSeq), params.maxBytes);
        return { events: page, hasMore, lastSeq: events.at(-1)!.seq };
      }
      return { events: [], hasMore: false, lastSeq: events.at(-1)!.seq };
    }
    default:
      return null;
  }
};

// ---- The bare page: no framework, the same socket and page, text into one scroller.
const BARE_HTML = `<!doctype html><html><head><meta charset="utf-8"><title>floor</title><style>
html,body{margin:0;height:100%;background:#1c1c1e;color:#e5e5e7;font:13px/1.5 -apple-system,system-ui,sans-serif}
#t{height:100%;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;padding:12px 16px;box-sizing:border-box}
#t>div{margin:0 0 6px}
</style></head><body><main id="t"></main><script>
function floorTexts(value, out, depth) {
  if (depth > 8 || value === null || typeof value !== "object") return;
  if (Array.isArray(value)) { for (const item of value) floorTexts(item, out, depth + 1); return; }
  for (const key in value) {
    const item = value[key];
    if ((key === "text" || key === "title" || key === "command") && typeof item === "string") out.push(item);
    else if (typeof item === "object") floorTexts(item, out, depth + 1);
  }
}
function floorDecode(data) { return JSON.parse(data); }
function floorRehydrate(records) {
  // One row per message or tool call (a streamed answer's chunks and a call's updates join into its row), else one
  // per run of records of a kind.
  const rows = [];
  const byKey = new Map();
  let kind = "";
  for (const record of records) {
    const texts = [];
    floorTexts(record.msg, texts, 0);
    if (texts.length === 0) continue;
    const text = texts.join("");
    const update = record.msg && record.msg.params && record.msg.params.update;
    const key = update && (update.messageId || update.toolCallId);
    if (key && byKey.has(key)) rows[byKey.get(key)] += text;
    else if (!key && record.kind === kind && rows.length > 0) rows[rows.length - 1] += text;
    else {
      if (key) byKey.set(key, rows.length);
      rows.push(text);
    }
    kind = record.kind;
  }
  return rows;
}
function floorMount(rows) {
  const scroller = document.getElementById("t");
  const fragment = document.createDocumentFragment();
  for (const row of rows) {
    const div = document.createElement("div");
    div.textContent = row;
    fragment.appendChild(div);
  }
  scroller.appendChild(fragment);
  scroller.scrollTop = scroller.scrollHeight;
}
const hash = new URLSearchParams(location.hash.slice(1));
const socket = new WebSocket(hash.get("endpoint"));
socket.onopen = () => socket.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "_acpmux/attach",
  params: { sessionId: hash.get("session"), bare: true } }));
socket.onmessage = (message) => {
  performance.mark("floor:attach");
  const reply = floorDecode(message.data);
  floorMount(floorRehydrate(reply.result.events));
};
</script></body></html>`;

// ---- The page probe: when the newest answer first painted, from the copy or the live page.
type Probe = { first: number; live: number; fcp: number; via: string };
function probe([target, hostTag]: [string, string]) {
  const record = { first: 0, live: 0, fcp: 0, via: "" };
  (window as unknown as { __floor: typeof record }).__floor = record;
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) if (entry.name === "first-contentful-paint") record.fcp = entry.startTime;
  }).observe({ type: "paint", buffered: true });
  // A message posted from a frame callback runs after that frame rendered (test/support/paintedFrames.ts).
  const after = new MessageChannel();
  let pending = "";
  after.port1.onmessage = () => {
    const now = performance.now();
    if (!record.first) {
      record.first = now;
      record.via = pending;
      performance.mark("floor:first-paint");
    }
    if (pending === "live" && !record.live) {
      record.live = now;
      performance.mark("floor:live-paint");
    }
  };
  // The chat's rows: the pane's transcript rows (data-row-id), the bare page's rows; `target`, when given, must
  // be among them too.
  const drawn = (scope: ParentNode | null | undefined): boolean => {
    const row = scope?.querySelector("[data-row-id], #t > div");
    if (!row || !(row.textContent ?? "").trim()) return false;
    return !target || ((scope as Element | ShadowRoot).textContent ?? "").includes(target);
  };
  const shows = (): string => {
    const root = document.getElementById("root") ?? document.getElementById("t");
    if (root && root.style.opacity !== "0" && drawn(root.parentElement)) return "live";
    const host = document.querySelector(hostTag) as HTMLElement | null;
    if (host && host.style.visibility !== "hidden" && drawn(host.shadowRoot)) return "copy";
    return "";
  };
  const tick = () => {
    const seen = shows();
    if (seen && (!record.first || seen === "live")) {
      pending = seen;
      after.port2.postMessage(0);
    }
    if (seen !== "live") requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

/// The live root's text, all of it and the part in view and drawn (the rest is mounted and unseen).
function hiddenText(): { mounted: number; visible: number; nodes: number } {
  const root = document.getElementById("root") ?? document.getElementById("t");
  if (!root) return { mounted: 0, visible: 0, nodes: 0 };
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let mounted = 0;
  let visible = 0;
  const seen = new Map<Element, boolean>();
  const shown = (element: Element): boolean => {
    let known = seen.get(element);
    if (known !== undefined) return known;
    const box = element.getBoundingClientRect();
    known =
      box.width > 0 &&
      box.height > 0 &&
      box.bottom > 0 &&
      box.top < innerHeight &&
      (element as HTMLElement).checkVisibility?.({ visibilityProperty: true, opacityProperty: true }) !== false;
    seen.set(element, known);
    return known;
  };
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = (node.textContent ?? "").trim().length;
    if (!length) continue;
    mounted += length;
    if (node.parentElement && shown(node.parentElement)) visible += length;
  }
  return { mounted, visible, nodes: root.getElementsByTagName("*").length };
}

// ---- The trace: stages of the main thread's time.
type TraceEvent = {
  name: string;
  cat?: string;
  ph: string;
  pid: number;
  tid: number;
  ts: number;
  dur?: number;
  id?: string;
  args?: { name?: string; data?: Record<string, unknown> };
};
type CallFrame = { functionName: string; url: string; lineNumber: number; columnNumber: number };
type ProfileNode = { id: number; parent?: number; callFrame: CallFrame };
const STAGES = ["boot", "decode", "rehydrate", "markdown", "mount", "layout", "paint", "other", "wait"] as const;
type Stage = (typeof STAGES)[number];
type Stages = Record<Stage, number>;
const zero = (): Stages => Object.fromEntries(STAGES.map((stage) => [stage, 0])) as Stages;
const LAYOUT_EVENTS = new Set(["UpdateLayoutTree", "Layout", "ParseAuthorStyleSheet", "RecalculateStyles"]);
const PAINT_EVENTS = new Set(["PrePaint", "Paint", "Layerize", "PaintImage", "Commit", "UpdateLayer"]);
const BOOT_EVENTS = new Set(["v8.compile", "v8.compileModule", "CompileScript", "v8.produceModuleCache"]);
/// Native work outside any script frame that loads the page and its scripts: parsing the document, compiling and
/// evaluating the bundle's modules, resolving their imports.
const BOOT_NATIVE = new Set([
  "ParseHTML",
  "v8.compile",
  "v8.compileModule",
  "v8.evaluateModule",
  "EvaluateScript",
  "v8.produceModuleCache",
  "v8.produceCache",
  "CompileScript",
  "CompileCode",
  "V8.CompileCode",
]);
/// Source files whose samples are the markdown stage (rendering markdown, highlighting code).
const MARKDOWN = /markdown|micromark|mdast|remark|rehype|marked|shiki|highlight|hast|unified|prism|lezer|katex/i;
/// Source files whose samples are the rehydrate stage: the transport, the store, the turn model.
const REHYDRATE =
  /acpmux\/(direct|bridgeSocket|transport|store|chatRows|model|conversation\/|tailCache|attach|records|events|reducer|sessionState|history|olderPages|pageRows|rows|turns|chatFromStore|hostRetry|chipMemory)|floorRehydrate|floorTexts|zustand|immer/;
/// React itself: rendering and committing.
const REACT = /node_modules\/(react-dom|react|scheduler)\/|floorMount/;

type Mapper = (file: string, line: number, column: number) => string;
function stagesOf(
  trace: TraceEvent[],
  url: string,
  mapper: Mapper,
  fromMark: string | undefined,
  toMark: string,
  files: Map<Stage, Map<string, number>>,
): { stages: Stages; wall: number } | undefined {
  // The page's renderer: the one whose main thread marked `toMark`.
  const mark = trace.find((event) => event.name === toMark && event.cat?.includes("blink.user_timing"));
  if (!mark) return undefined;
  const { pid, tid } = mark;
  const nav = trace
    .filter(
      (event) =>
        event.pid === pid &&
        event.name === "navigationStart" &&
        String((event.args?.data as { documentLoaderURL?: string } | undefined)?.documentLoaderURL ?? "").startsWith(
          url.split("#")[0]!,
        ),
    )
    .sort((a, b) => a.ts - b.ts)[0];
  if (!nav) return undefined;
  const start = fromMark
    ? (trace.find((event) => event.pid === pid && event.name === fromMark && event.cat?.includes("blink.user_timing"))
        ?.ts ?? nav.ts)
    : nav.ts;
  const end = mark.ts;
  const stages = zero();
  const main = trace.filter((event) => event.pid === pid && event.tid === tid);
  // Top-level spans of style and layout, of paint and of script compiles (nested ones counted once).
  const spans = (names: Set<string>) => {
    const out: [number, number][] = [];
    for (const event of main)
      if (names.has(event.name) && event.ph === "X" && event.dur !== undefined)
        out.push([event.ts, event.ts + event.dur]);
    out.sort((a, b) => a[0] - b[0]);
    const merged: [number, number][] = [];
    for (const span of out)
      if (merged.length && span[0] <= merged.at(-1)![1]) merged.at(-1)![1] = Math.max(merged.at(-1)![1], span[1]);
      else merged.push([...span]);
    return merged;
  };
  const layout = spans(LAYOUT_EVENTS);
  const paint = spans(PAINT_EVENTS);
  const compile = spans(BOOT_EVENTS);
  const inside = (spansOf: [number, number][], ts: number) => {
    let low = 0;
    let high = spansOf.length - 1;
    while (low <= high) {
      const mid = (low + high) >> 1;
      const [a, b] = spansOf[mid]!;
      if (ts < a) high = mid - 1;
      else if (ts >= b) low = mid + 1;
      else return true;
    }
    return false;
  };
  // The sampling profile of that thread: nodes come in chunks, each sample a node id and a time delta.
  const profiles = trace.filter((event) => event.name === "Profile" && event.pid === pid && event.tid === tid);
  const ids = new Set(profiles.map((event) => event.id));
  const nodes = new Map<number, ProfileNode>();
  const samples: { ts: number; node: number }[] = [];
  for (const profile of profiles) {
    let clock = Number((profile.args?.data as { startTime?: number } | undefined)?.startTime ?? profile.ts);
    for (const chunk of trace.filter((event) => event.name === "ProfileChunk" && event.id === profile.id)) {
      const data = chunk.args?.data as {
        cpuProfile?: { nodes?: ProfileNode[]; samples?: number[] };
        timeDeltas?: number[];
      };
      // A trace's nodes leave out empty fields.
      for (const node of data.cpuProfile?.nodes ?? [])
        nodes.set(node.id, {
          ...node,
          callFrame: { functionName: "", url: "", lineNumber: 0, columnNumber: 0, ...node.callFrame },
        });
      const ids = data.cpuProfile?.samples ?? [];
      ids.forEach((node, at) => {
        clock += data.timeDeltas?.[at] ?? 0;
        samples.push({ ts: clock, node });
      });
    }
  }
  if (ids.size === 0 || samples.length === 0) return undefined;
  const where = new Map<number, string>();
  const placeOf = (node: ProfileNode): string => {
    let known = where.get(node.id);
    if (known !== undefined) return known;
    const { url: frameUrl, lineNumber, columnNumber, functionName } = node.callFrame;
    const file = frameUrl.split("/").at(-1) ?? "";
    known =
      frameUrl.startsWith("http") && file ? mapper(file, lineNumber, columnNumber) : `${functionName || "(native)"}`;
    if (frameUrl.startsWith("http") && !file.endsWith(".js")) known = functionName || file;
    where.set(node.id, known);
    return known;
  };
  const classify = (leaf: ProfileNode): [Stage, string] => {
    const name = leaf.callFrame.functionName;
    if (name === "(garbage collector)" || name === "(program)" || name === "(root)") return ["other", name];
    if (leaf.callFrame.url === "" && name === "parse") return ["decode", "JSON.parse"];
    let place = "";
    for (let node: ProfileNode | undefined = leaf; node; node = node.parent ? nodes.get(node.parent) : undefined) {
      if (!node.callFrame.url.startsWith("http")) continue;
      const at = placeOf(node);
      place ||= at;
      if (/floorDecode/.test(node.callFrame.functionName)) return ["decode", at];
      if (MARKDOWN.test(at)) return ["markdown", at];
      if (REHYDRATE.test(at) || /floorRehydrate|floorTexts/.test(node.callFrame.functionName)) return ["rehydrate", at];
      if (REACT.test(at) || /floorMount/.test(node.callFrame.functionName)) return ["mount", place];
      if (/\.tsx:/.test(at)) return ["mount", at];
    }
    return ["other", place || name];
  };
  // The innermost main-thread trace event each sample falls in (a sweep: events by start, a stack of open ones).
  const spansSorted = main
    .filter((event) => event.ph === "X" && (event.dur ?? 0) > 0 && event.ts <= end && event.ts + event.dur! >= start)
    .sort((a, b) => a.ts - b.ts || b.dur! - a.dur!);
  const innermost = new Map<number, string>();
  {
    const open: TraceEvent[] = [];
    let next = 0;
    const ordered = samples.map((sample, at) => [sample.ts, at] as const).sort((a, b) => a[0] - b[0]);
    for (const [ts, at] of ordered) {
      while (next < spansSorted.length && spansSorted[next]!.ts <= ts) open.push(spansSorted[next++]!);
      for (let i = open.length - 1; i >= 0; i--) if (open[i]!.ts + open[i]!.dur! < ts) open.splice(i, 1);
      if (open.length) innermost.set(at, open.at(-1)!.name);
    }
  }
  let previous = start;
  let sampleAt = -1;
  for (const sample of samples) {
    sampleAt++;
    if (sample.ts < start || sample.ts > end) continue;
    const ms = (sample.ts - previous) / 1000;
    previous = sample.ts;
    const node = nodes.get(sample.node);
    if (!node || node.callFrame.functionName === "(idle)") continue;
    let stage: Stage;
    let place: string;
    if (inside(layout, sample.ts)) [stage, place] = ["layout", "style+layout"];
    else if (inside(paint, sample.ts)) [stage, place] = ["paint", "paint"];
    else {
      [stage, place] = classify(node);
      if (stage === "other" && inside(compile, sample.ts)) [stage, place] = ["boot", "compile"];
      else if (stage === "other" && place === "(program)") {
        const event = innermost.get(sampleAt) ?? "none";
        [stage, place] = BOOT_NATIVE.has(event) ? ["boot", event] : ["other", `(program) in ${event}`];
      }
    }
    stages[stage] += ms;
    const byFile = files.get(stage) ?? new Map<string, number>();
    const key = place.replace(/:\d+$/, "");
    byFile.set(key, (byFile.get(key) ?? 0) + ms);
    files.set(stage, byFile);
  }
  // Script work before the page's own first function ran is the boot: evaluate events with nothing under them
  // the classifier knew are already `other`; the compile spans are `boot` above.
  const wall = (end - start) / 1000;
  const busy = STAGES.filter((stage) => stage !== "wait").reduce((sum, stage) => sum + stages[stage], 0);
  stages.wait = Math.max(0, wall - busy);
  return { stages, wall };
}

const TRACE_CATEGORIES = [
  "__metadata",
  "toplevel",
  "blink.user_timing",
  "loading",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "v8.execute",
  "v8",
  "disabled-by-default-v8.cpu_profiler",
  "disabled-by-default-v8.cpu_profiler.hires",
];
async function traced<T>(cdp: CDPSession, run: () => Promise<T>): Promise<{ result: T; trace: TraceEvent[] }> {
  const trace: TraceEvent[] = [];
  const collect = (payload: { value: object[] }) => {
    for (const event of payload.value) trace.push(event as TraceEvent);
  };
  cdp.on("Tracing.dataCollected", collect);
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { includedCategories: TRACE_CATEGORIES, excludedCategories: ["*"] },
  });
  try {
    const result = await run();
    const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
    await cdp.send("Tracing.end");
    await done;
    return { result, trace };
  } finally {
    cdp.off("Tracing.dataCollected", collect);
  }
}

const median = (values: number[]) => {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (sorted.length === 0) return NaN;
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
};
const p95 = (values: number[]) => {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)] ?? NaN;
};

const releases: (() => unknown)[] = [];
try {
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        const result = answer(message.method, message.params);
        const text = JSON.stringify({ jsonrpc: "2.0", id: message.id, result });
        if (message.method === "_acpmux/attach") attachBytes = text.length;
        ws.send(text);
      },
    },
  });
  releases.push(() => daemon.stop(true));

  // The pane as the app serves it (first-load-after-restart.bench.ts): one linked pane.css with the copy's
  // pane-copy.css beside it, and the host's snapshot script and the boot script before the module.
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-floor-bench-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const sourceRef = process.env.PANE_SOURCE_REF;
  const priorSources = new Map<string, string>();
  if (sourceRef) {
    const changed = execFileSync(
      "git",
      ["diff", "--name-only", "--diff-filter=MD", sourceRef, "--", "src/agent-session", "src/ui"],
      { cwd: webviews, encoding: "utf8" },
    )
      .split("\n")
      .filter(Boolean);
    const top = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: webviews, encoding: "utf8" }).trim();
    for (const file of changed)
      priorSources.set(
        path.join(top, file),
        execFileSync("git", ["show", `${sourceRef}:${file}`], {
          cwd: webviews,
          encoding: "utf8",
          maxBuffer: 8 * 1024 * 1024,
        }),
      );
    console.log(`pane sources read at ${sourceRef}: ${changed.join(", ") || "none"}`);
  }
  const { build } = await import("vite");
  await build({
    plugins: [{ name: "immutable-pane-baseline", enforce: "pre", load: (id) => priorSources.get(id) }],
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    // Minified as it ships; the source map names each sample's file (it does not change what runs).
    build: { outDir: out, emptyOutDir: true, sourcemap: true },
    logLevel: "error",
  });
  const bundle = async (entry: string): Promise<string> => {
    const built = await Bun.build({ entrypoints: [entry], format: "iife", target: "browser" });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    return await built.outputs[0]!.text();
  };
  const readSource = (file: string) => priorSources.get(file);
  // The boot script at the ref too, so a before/after builds the whole page at one revision.
  const bootEntry = path.join(chatSnapshotSource, "boot.ts");
  const bootScript = readSource(bootEntry) === undefined ? await bundle(bootEntry) : await bundleAt(bootEntry);
  async function bundleAt(entry: string): Promise<string> {
    const built = await Bun.build({
      entrypoints: [entry],
      format: "iife",
      target: "browser",
      plugins: [
        {
          name: "at-ref",
          setup(builder) {
            builder.onLoad({ filter: /\.ts$/ }, (args) => {
              const prior = priorSources.get(args.path);
              return prior === undefined ? undefined : { contents: prior, loader: "ts" };
            });
          },
        },
      ],
    });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    return await built.outputs[0]!.text();
  }
  const captureEntry = path.join(out, "capture-entry.ts");
  fs.writeFileSync(
    captureEntry,
    `import { captureMiss, captureSnapshot } from ${JSON.stringify(path.join(chatSnapshotSource, "capture.ts"))};\n` +
      "Object.assign(globalThis, { captureMiss, captureSnapshot });\n",
  );
  const captureScript = await bundle(captureEntry);
  let index = fs.readFileSync(path.join(out, "index.html"), "utf8");
  const linked: string[] = [];
  index = index.replace(/<link\b[^>]*\brel="stylesheet"[^>]*>/g, (tag) => {
    const href = /\bhref="([^"]+)"/.exec(tag)?.[1];
    if (href) linked.push(href.replace(/^\.?\//, ""));
    return "";
  });
  const assets = fs.existsSync(path.join(out, "assets")) ? fs.readdirSync(path.join(out, "assets")) : [];
  const sheets = [
    ...linked,
    ...assets
      .filter((name) => name.endsWith(".css"))
      .map((name) => `assets/${name}`)
      .filter((name) => !linked.includes(name))
      .sort(),
  ];
  const css = sheets
    .map((sheet) =>
      fs
        .readFileSync(path.join(out, sheet), "utf8")
        .replace(
          /url\((["']?)(?![a-z]+:|\/|#)([^"')]+)\1\)/gi,
          (_match, quote: string, file: string) =>
            `url(${quote}/${path.posix.join(path.posix.dirname(sheet), file)}${quote})`,
        ),
    )
    .join("\n");
  fs.writeFileSync(path.join(out, "pane.css"), css);
  fs.writeFileSync(path.join(out, "pane-copy.css"), snapshotCss(css));
  const placeholders = sheets.map((sheet) => `<link rel="stylesheet" media="not all" href="/${sheet}">`).join("\n");
  index = index.replace(
    "</head>",
    () =>
      `<link rel="stylesheet" id="${PAGE_STYLE_ID}" href="/pane.css" data-copy="pane-copy.css">\n${placeholders}\n</head>`,
  );
  index = index.replace(
    /<main id="root"><\/main>/,
    () =>
      '<main id="root"></main>\n<script async src="/__snapshot/chat.js"></script>\n<script src="/chat-snapshot.js"></script>',
  );
  let servedCopy: ChatSnapshot | null = null;
  const script = (body: string) =>
    new Response(body, { headers: { "Content-Type": "text/javascript", "Cache-Control": "no-store" } });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      if (pathname === "/" || pathname === "/index.html")
        return new Response(index, { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
      if (pathname === "/bare.html")
        return new Response(BARE_HTML, { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
      if (pathname === "/__snapshot/chat.js")
        return script(
          `self.${SNAPSHOT_GLOBAL}=${JSON.stringify(servedCopy)};self.${SNAPSHOT_THEME_GLOBAL}=${JSON.stringify(THEME)};self.__cmuxRestoredChat=${JSON.stringify(SESSION_ID)};self.dispatchEvent(new Event('cmux-restored-chat'));self.${SNAPSHOT_BOOT_GLOBAL}?.();`,
        );
      if (pathname === "/chat-snapshot.js") return script(bootScript);
      const file = Bun.file(path.join(out, pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const hash = `#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${SESSION_ID}`;
  const urlOf = (mode: Mode) =>
    mode === "bare" ? `http://127.0.0.1:${statics.port}/bare.html${hash}` : `http://127.0.0.1:${statics.port}/${hash}`;
  const browser: Browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  const mapper = sourceMapper(out);

  type Load = { probe: Probe; hidden: ReturnType<typeof hiddenText>; trace?: TraceEvent[] };
  const load = async (mode: Mode, trace: boolean): Promise<Load> => {
    servedCopy = mode === "pane-copy" ? copy : null;
    const context = await browser.newContext({ viewport: VIEWPORT });
    try {
      const page = await context.newPage();
      const cdp = await context.newCDPSession(page);
      if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
      await page.addInitScript(probe, [LATEST, SNAPSHOT_HOST_TAG] as [string, string]);
      const run = async () => {
        await page.goto(urlOf(mode));
        await page
          .waitForFunction(() => (window as unknown as { __floor: Probe }).__floor.live > 0, undefined, {
            timeout: 60_000,
            polling: 50,
          })
          .catch(async (error: unknown) => {
            const state = await page.evaluate((hostTag) => {
              const root = document.getElementById("root") ?? document.getElementById("t");
              return JSON.stringify({
                floor: (window as unknown as { __floor: Probe }).__floor,
                opacity: root?.style.opacity,
                host: !!document.querySelector(hostTag),
                tail: (root as HTMLElement | null)?.innerText.slice(-600),
              });
            }, SNAPSHOT_HOST_TAG);
            throw new Error(`${mode}: the live page never drew "${LATEST}": ${state}\n${String(error)}`);
          });
        return (await page.evaluate(() => (window as unknown as { __floor: Probe }).__floor)) as Probe;
      };
      const browserCdp = trace ? await browser.newBrowserCDPSession() : undefined;
      const got = browserCdp ? await traced(browserCdp, run) : { result: await run(), trace: undefined };
      const hidden = await page.evaluate(hiddenText);
      return { probe: got.result, hidden, trace: got.trace };
    } finally {
      await context.close();
    }
  };

  // The warm load that writes the copy the pane-copy rounds are served.
  let copy: ChatSnapshot | null = null;
  if (MODES.includes("pane-copy")) {
    const context = await browser.newContext({ viewport: VIEWPORT });
    const page = await context.newPage();
    await page.addInitScript(probe, [LATEST, SNAPSHOT_HOST_TAG] as [string, string]);
    await page.goto(urlOf("pane"));
    await page
      .waitForFunction(() => (window as unknown as { __floor: Probe }).__floor.live > 0, undefined, { timeout: 60_000 })
      .catch(async (error: unknown) => {
        const shown = await page.evaluate(() => document.getElementById("root")?.innerText.slice(-1500) ?? "(no root)");
        throw new Error(`the pane never drew "${LATEST}"; its root ends:\n${shown}\n${String(error)}`);
      });
    // fixed-wait: the chat settles (its older page, its measured rows) before the copy is written, as the page
    // writes it once its launch settled (chatSnapshot/live.ts).
    await page.waitForTimeout(1500);
    await page.addScriptTag({ content: captureScript });
    const written = await page.evaluate((theme) => {
      const w = window as unknown as {
        captureSnapshot: (doc: Document, theme: string) => ChatSnapshot | undefined;
        captureMiss: () => string;
      };
      const snapshot = w.captureSnapshot(document, theme);
      return { snapshot: snapshot ?? null, miss: snapshot ? "" : w.captureMiss() };
    }, THEME);
    await context.close();
    if (!written.snapshot) throw new Error(`the settled pane wrote no copy: ${written.miss}`);
    copy = written.snapshot;
    console.log(`copy: ${(copy.html.length / 1024).toFixed(0)} KiB of markup`);
  }

  const timed = new Map<Mode, Load[]>(MODES.map((mode) => [mode, []]));
  // Rounds interleave the modes, so a busy minute of the host lands on all of them.
  for (let round = 0; round < ROUNDS; round++) for (const mode of MODES) timed.get(mode)!.push(await load(mode, false));
  const breakdowns = new Map<Mode, { toFirst: Stages[]; toLive: Stages[]; files: Map<Stage, Map<string, number>> }>();
  for (const mode of MODES) {
    const entry = { toFirst: [] as Stages[], toLive: [] as Stages[], files: new Map<Stage, Map<string, number>>() };
    for (let round = 0; round < TRACE_ROUNDS; round++) {
      const got = await load(mode, true);
      const url = urlOf(mode);
      const first = stagesOf(got.trace!, url, mapper, undefined, "floor:first-paint", entry.files);
      if (first) entry.toFirst.push(first.stages);
      if (got.probe.via === "copy") {
        const live = stagesOf(got.trace!, url, mapper, "floor:first-paint", "floor:live-paint", new Map());
        if (live) entry.toLive.push(live.stages);
      }
    }
    breakdowns.set(mode, entry);
  }

  const fmt = (value: number) => (Number.isFinite(value) ? value.toFixed(0).padStart(6) : "     -");
  console.log(
    `\nchat floor: ${recorded.length * Math.max(1, REPEAT)} records (${turnCount} turns), attach page ${attachRecords} records, ${(attachBytes / 1024).toFixed(0)} KiB; ` +
      `${ROUNDS} cold rounds per mode, ${TRACE_ROUNDS} traced; CPU x${CPU}; first paint: ${LATEST ? `rows holding "${LATEST}"` : "the first drawn transcript rows"}`,
  );
  console.log(`\nmode        first    p95   live    fcp  via   text mounted/visible  nodes`);
  const json: Record<string, unknown> = {
    records: events.length,
    attachRecords,
    attachBytes,
    rounds: ROUNDS,
    traceRounds: TRACE_ROUNDS,
    cpu: CPU,
    source: sourceRef ?? "worktree",
  };
  for (const mode of MODES) {
    const loads = timed.get(mode)!;
    const first = loads.map((l) => l.probe.first);
    const live = loads.map((l) => l.probe.live);
    const fcp = loads.map((l) => l.probe.fcp);
    const hidden = loads.at(-1)!.hidden;
    console.log(
      `${mode.padEnd(10)} ${fmt(median(first))} ${fmt(p95(first))} ${fmt(median(live))} ${fmt(median(fcp))}  ${(loads.at(-1)!.probe.via || "-").padEnd(5)} ${String(hidden.mounted).padStart(8)}/${String(hidden.visible).padEnd(8)} ${String(hidden.nodes).padStart(9)}`,
    );
    perfRow({ name: `chat_floor.${mode}.first`, p50: median(first), p95: p95(first), samples: first });
    perfRow({ name: `chat_floor.${mode}.live`, p50: median(live), p95: p95(live), samples: live });
    json[mode] = { first, live, fcp, hidden };
  }
  const stageLine = (label: string, rows: Stages[]) => {
    const med = zero();
    for (const stage of STAGES) med[stage] = median(rows.map((row) => row[stage]));
    console.log(`${label.padEnd(22)} ${STAGES.map((stage) => fmt(med[stage])).join(" ")}`);
    return med;
  };
  console.log(
    `\nmain thread ms, median of traced rounds\n${"".padEnd(22)} ${STAGES.map((s) => s.padStart(6)).join(" ")}`,
  );
  for (const mode of MODES) {
    const entry = breakdowns.get(mode)!;
    const stages: Record<string, Stages> = {};
    if (entry.toFirst.length) stages.toFirst = stageLine(`${mode} nav->first`, entry.toFirst);
    if (entry.toLive.length) stages.toLive = stageLine(`${mode} first->live`, entry.toLive);
    (json[mode] as Record<string, unknown>).stages = stages;
    if (TOP > 0)
      for (const stage of STAGES) {
        const byFile = [...(entry.files.get(stage) ?? new Map<string, number>()).entries()]
          .sort((a, b) => b[1] - a[1])
          .slice(0, TOP);
        if (byFile.length)
          console.log(
            `  ${mode} ${stage}: ${byFile.map(([file, ms]) => `${file} ${(ms / Math.max(1, TRACE_ROUNDS)).toFixed(1)}`).join(", ")}`,
          );
      }
  }
  console.log(`CHAT_FLOOR_JSON ${JSON.stringify(json)}`);
} finally {
  for (const release of releases.reverse()) await Promise.resolve(release()).catch(() => undefined);
}
