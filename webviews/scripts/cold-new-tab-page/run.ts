#!/usr/bin/env bun
// Measure only, never merges (decision 2026-11-16): a COLD New Tab page of the agent pane as the app
// ships it (scripts/cmux-next/build-agent-pane-web.sh --out DIR), from the navigation to the frame
// that shows the bar, in a Chromium of Playwright, with a mocked page host.
//
// What a number of this script is, and is not:
//   - The page files are the shipped build. The host is a mock: it answers with no delay, so the
//     time of the app's own answer is NOT in these times. The two context arms differ in the ORDER
//     only (one more render and one more turn of the page for the `call` arm).
//   - The files come from a local server with the app's own cache header for its page files
//     (`Cache-Control: no-store`, AgentPaneSchemeHandler+Headers.swift). `--cache` serves them with a
//     cache header instead (a report of what the browser's caches give).
//   - The handshake is never answered: the page is in its state before the agent host answers, which
//     is the state a cold New Tab page first shows.
//   - The times are of this machine and this browser, not of a Mac and not of the app's engine.
//   - `--one-profile` keeps one browser profile on disk for the runs of an arm (a new page each, in
//     the same context), so the browser's caches live from run to run; it prints each run's total in
//     order. Without it each page is in a new context of its own. No coverage and no trace then.
//   - `--trace` adds one more run for each arm with the browser's own trace on (not timed with the
//     others: the trace slows the page): the main thread's time by event name in each part, as self
//     time (an event's time less the time of the events inside it).
//
// Usage:
//   bun scripts/cold-new-tab-page/run.ts --dist DIR --out FILE.json [--runs 10] [--cache] [--one-profile] [--probe DIR] [--trace]
//
// Arms: context `call` (the page asks `newTab.context` in an effect: the Chromium way) and context
// `document` (`window.__cmuxNewTabContext` is there before the page's scripts: the WebKit way), each
// with a bar of 0 rows and with the rows of a session of 826 workspaces and 1,600 tabs.
// Each arm starts a new browser (a new profile); each run is a new page; run 1 is reported alone.
//
// The parts of a run, from the navigation's start: (1) the document's own files are in; (2) the
// scripts ran to the page's first message to its host (compile and evaluate); (3) React's first
// commit; (4) the bar is in the DOM; (5) the frame with the bar has painted. `long tasks` is the sum
// of the main thread's tasks of more than 50 ms before that frame, as the browser reports them.
import fs from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";

type Size = "empty" | "session";
type Way = "call" | "document";
interface Arm {
  way: Way;
  size: Size;
}

interface PageTrace {
  calls: { op: string; at: number }[];
  marks: Record<string, number>;
  paints: Record<string, number>;
  longTasks: { start: number; duration: number }[];
  errors: string[];
}

interface Resource {
  name: string;
  type: string;
  start: number;
  end: number;
  bytes: number;
}

interface Run {
  marks: Record<string, number>;
  paints: Record<string, number>;
  calls: { op: string; at: number }[];
  longTasks: { start: number; duration: number }[];
  navigation: { responseEnd: number; domInteractive: number; domContentLoaded: number };
  resources: Resource[];
  errors: string[];
  parts: Record<string, number>;
}

const SELECTOR = ".nt-screen .nt-field";
const VIEWPORT = { width: 1200, height: 800 };
const TYPES: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
};

function options(args: string[]) {
  const values = new Map<string, string>();
  const flags = new Set<string>();
  for (let i = 0; i < args.length; i++) {
    if (["--cache", "--trace", "--one-profile"].includes(args[i])) flags.add(args[i]);
    else if (["--dist", "--out", "--runs", "--probe"].includes(args[i])) values.set(args[i], args[++i] ?? "");
    else throw new Error(`unknown argument ${args[i]}`);
  }
  const dist = values.get("--dist");
  const out = values.get("--out");
  if (!dist || !out) throw new Error("usage: run.ts --dist DIR --out FILE.json [--runs 10] [--cache] [--one-profile] [--probe DIR] [--trace]");
  return {
    dist: path.resolve(dist),
    out: path.resolve(out),
    runs: Number(values.get("--runs") ?? "10"),
    cache: flags.has("--cache"),
    trace: flags.has("--trace"),
    oneProfile: flags.has("--one-profile"),
    probe: values.get("--probe") ? path.resolve(values.get("--probe") as string) : undefined,
  };
}

/** The context a New Tab page gets, in the keys the app encodes (AgentPaneNewTab, AgentPaneOmnibar). */
function context(size: Size): unknown {
  const home = "/Users/dev";
  const tabs: unknown[] = [];
  const workspaces: unknown[] = [];
  const folders: string[] = [];
  if (size === "session") {
    // 826 workspaces with 1,600 tabs: 774 workspaces of two terminals and 52 of one. A workspace of
    // one place lists as that tab only (NewTabPlaces.places), and the first is the window's own.
    let tab = 0;
    for (let index = 0; index < 826; index++) {
      const name = `workspace ${index + 1} of the session`;
      const folder = `${home}/code/project-${String(index + 1).padStart(3, "0")}`;
      const count = index < 774 ? 2 : 1;
      for (let nth = 0; nth < count; nth++) {
        tab += 1;
        tabs.push({
          id: `00000000-0000-4000-8000-${String(tab).padStart(12, "0")}`,
          kind: "terminal",
          title: nth === 0 ? `~/code/project-${String(index + 1).padStart(3, "0")}` : `make test ${tab}`,
          ...(nth === 0 ? {} : { detail: `~/code/project-${String(index + 1).padStart(3, "0")}` }),
          workspace: name,
        });
      }
      folders.push(folder);
      if (index > 0 && count !== 1)
        workspaces.push({
          id: `10000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
          name,
          detail: `~/code/project-${String(index + 1).padStart(3, "0")}`,
        });
    }
  }
  return {
    kind: "agent",
    hotkeys: { terminal: "⌘T", browser: "⌘⇧B", agent: "⌘⇧A" },
    cwd: `${home}/code/project-001`,
    host: "this-mac",
    omnibar: { tabs, workspaces, folders, projects: [], actions: [], commands: [], history: [], uses: {} },
    projects: [],
    layout: "b",
    home,
    focusesField: true,
    start: { cwd: `${home}/code/project-001`, chooseFolder: false },
  };
}

/** Runs in the page before each of its scripts: the mocked host and the marks. Closes over nothing. */
function install(setup: { way: string; json: string; selector: string }) {
  const trace: PageTrace = { calls: [], marks: {}, paints: {}, longTasks: [], errors: [] };
  (window as unknown as { __coldTrace: PageTrace }).__coldTrace = trace;
  const mark = (name: string) => {
    if (trace.marks[name] === undefined) trace.marks[name] = performance.now();
  };
  let nextSub = 1;
  const handler = {
    postMessage(envelope: { t: string; id?: number; op?: string; stream?: string }): Promise<unknown> {
      mark("firstHostMessage");
      if (envelope.t === "call") {
        trace.calls.push({ op: envelope.op ?? "", at: performance.now() });
        if (envelope.op === "cmux.agent.newTab.context") {
          mark("contextAsked");
          // The app's answer is JSON that the page's side decodes: the decode is in the measure.
          const value = { newTab: JSON.parse(setup.json) as unknown };
          mark("contextAnswered");
          return Promise.resolve({ t: "ok", id: envelope.id, value });
        }
        // The agent host has not answered yet: the handshake stays open.
        if (envelope.op === "cmux.agent.handshake") return new Promise(() => undefined);
        return Promise.resolve({ t: "ok", id: envelope.id, value: null });
      }
      if (envelope.t === "sub") {
        trace.calls.push({ op: `sub ${envelope.stream ?? ""}`, at: performance.now() });
        return Promise.resolve({ t: "ok", id: envelope.id, value: { sub: nextSub++ } });
      }
      return Promise.resolve(undefined);
    },
  };
  (window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: handler } };
  addEventListener("error", (event) => trace.errors.push(`error: ${event.message}`));
  addEventListener("unhandledrejection", (event) => trace.errors.push(`rejection: ${String(event.reason)}`));
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) trace.paints[entry.name] = entry.startTime;
    }).observe({ type: "paint", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) trace.paints["largest-contentful-paint"] = entry.startTime;
    }).observe({ type: "largest-contentful-paint", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) trace.longTasks.push({ start: entry.startTime, duration: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // An engine without one of these entry types reports the marks only.
  }
  const observer = new MutationObserver(() => {
    const root = document.getElementById("root");
    if (root?.firstChild) mark("firstCommit");
    if (trace.marks.bar !== undefined || !document.querySelector(setup.selector)) return;
    mark("bar");
    observer.disconnect();
    // A frame callback runs before the frame's style, layout and paint; a message posted from it runs
    // after the frame has rendered (test/support/paintedFrames.ts).
    requestAnimationFrame(() => {
      mark("barFrame");
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        channel.port1.close();
        mark("barPainted");
        (window as unknown as { __coldTraceDone?: () => void }).__coldTraceDone?.();
      };
      channel.port2.postMessage(null);
    });
  });
  observer.observe(document, { childList: true, subtree: true });
  if (setup.way === "document") {
    // The app writes the context as the document commits (AgentPaneNavigation.swift).
    (window as unknown as { __cmuxNewTabContext: unknown }).__cmuxNewTabContext = JSON.parse(setup.json);
  }
}

function serve(dist: string, cache: boolean): Promise<http.Server> {
  const server = http.createServer((request, response) => {
    const name = decodeURIComponent((request.url ?? "/").split("?")[0]);
    const headers: Record<string, string> = {
      "Cache-Control": cache ? "max-age=3600" : "no-store",
      "X-Content-Type-Options": "nosniff",
    };
    // The kept copy of a chat: the app's page host answers it per page; a New Tab page has none.
    if (name === "/__snapshot/chat.js") {
      response.writeHead(200, { ...headers, "Content-Type": "text/javascript", "Content-Length": "0" });
      response.end();
      return;
    }
    const file = path.join(dist, name === "/" ? "index.html" : name);
    if (!file.startsWith(dist + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      response.writeHead(404, headers);
      response.end();
      return;
    }
    const data = fs.readFileSync(file);
    response.writeHead(200, {
      ...headers,
      "Content-Type": TYPES[path.extname(file)] ?? "application/octet-stream",
      "Content-Length": String(data.length),
    });
    response.end(data);
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

/** A new page with the mocked host; `done` resolves when the frame that shows the bar has painted. */
async function open(
  browser: Browser | BrowserContext,
  arm: Arm,
  json: string,
): Promise<{ page: Page; done: Promise<void> }> {
  // A page of a browser is in a new context of its own (no cache of another page); a page of a
  // kept profile shares that profile's caches.
  const page = await ("newContext" in browser ? browser.newPage({ viewport: VIEWPORT }) : browser.newPage());
  let finish: () => void = () => undefined;
  const done = new Promise<void>((resolve) => (finish = resolve));
  await page.exposeFunction("__coldTraceDone", () => finish());
  await page.addInitScript(install, { way: arm.way, json, selector: SELECTOR });
  return { page, done };
}

async function read(page: Page): Promise<Run> {
  // Two more frames, so the paint entries of the bar's frame are listed.
  await page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null)))),
  );
  const raw = await page.evaluate(() => {
    const trace = (window as unknown as { __coldTrace: PageTrace }).__coldTrace;
    const navigation = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming;
    const resources = (performance.getEntriesByType("resource") as PerformanceResourceTiming[]).map((entry) => ({
      name: entry.name.replace(/^https?:\/\/[^/]+\//, "").split("?")[0],
      type: entry.initiatorType,
      start: entry.startTime,
      end: entry.responseEnd,
      bytes: entry.decodedBodySize,
    }));
    return {
      marks: trace.marks,
      paints: trace.paints,
      calls: trace.calls,
      longTasks: trace.longTasks,
      errors: trace.errors,
      navigation: {
        responseEnd: navigation.responseEnd,
        domInteractive: navigation.domInteractive,
        domContentLoaded: navigation.domContentLoadedEventEnd,
      },
      resources,
    };
  });
  const { marks, navigation, resources } = raw;
  // The files of the document itself (its scripts, their static imports and its sheet): each was
  // asked before the parser ended. A file that the page's code asks later is not in this part.
  const fixedFiles = resources.filter((entry) => entry.start < navigation.domInteractive);
  const filesIn = Math.max(navigation.responseEnd, ...fixedFiles.map((entry) => entry.end));
  const tasks = raw.longTasks.filter((task) => task.start < marks.barPainted);
  const parts = {
    "1 files in": filesIn,
    "2 scripts run": marks.firstHostMessage - filesIn,
    "3 first commit": marks.firstCommit - marks.firstHostMessage,
    "4 bar in the DOM": marks.bar - marks.firstCommit,
    "5 bar painted": marks.barPainted - marks.bar,
    total: marks.barPainted,
    "long tasks": tasks.reduce((sum, task) => sum + task.duration, 0),
  };
  return { ...raw, parts };
}

/** The bytes of `text` that ran, from V8's block coverage (inner ranges come after their outer). */
function ranBytes(length: number, functions: { ranges: { startOffset: number; endOffset: number; count: number }[] }[]) {
  const ran = new Uint8Array(length);
  const ranges = functions.flatMap((one) => one.ranges);
  ranges.sort((a, b) => a.startOffset - b.startOffset || b.endOffset - a.endOffset);
  for (const range of ranges) ran.fill(range.count > 0 ? 1 : 0, range.startOffset, range.endOffset);
  let sum = 0;
  for (const byte of ran) sum += byte;
  return sum;
}

async function coverage(browser: Browser, url: string, arm: Arm, json: string) {
  const { page, done } = await open(browser, arm, json);
  await page.coverage.startJSCoverage({ resetOnNavigation: false });
  await page.coverage.startCSSCoverage({ resetOnNavigation: false });
  await page.goto(url, { waitUntil: "commit" });
  await done;
  const [scripts, sheets] = [await page.coverage.stopJSCoverage(), await page.coverage.stopCSSCoverage()];
  await page.close();
  const short = (name: string) => name.replace(/^https?:\/\/[^/]+\//, "").split("?")[0];
  return {
    scripts: scripts
      .filter((entry) => entry.url.startsWith("http"))
      .map((entry) => ({
        name: short(entry.url),
        bytes: entry.source?.length ?? 0,
        ran: ranBytes(entry.source?.length ?? 0, entry.functions),
      })),
    sheets: sheets.map((entry) => ({
      name: short(entry.url),
      bytes: entry.text?.length ?? 0,
      ran: entry.ranges.reduce((sum, range) => sum + range.end - range.start, 0),
    })),
  };
}

interface TraceEvent {
  ph: string;
  name: string;
  pid: number;
  tid: number;
  ts: number;
  dur?: number;
  args?: { data?: { documentLoaderURL?: string } };
}

const TRACE_CATEGORIES = [
  "blink.user_timing",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-v8.compile",
  "loading",
  "v8",
  "v8.execute",
];

/** One run with the browser's trace: the page's main thread by event name (self time, ms) in each part. */
async function traced(browser: Browser, url: string, arm: Arm, json: string) {
  const { page, done } = await open(browser, arm, json);
  await browser.startTracing(page, { categories: TRACE_CATEGORIES });
  await page.goto(url, { waitUntil: "commit" });
  await done;
  const run = await read(page);
  const buffer = await browser.stopTracing();
  await page.close();
  const events = (JSON.parse(buffer.toString("utf8")) as { traceEvents: TraceEvent[] }).traceEvents;
  // The navigation of the page gives the time's start and the page's main thread.
  const start = events.find((event) => event.name === "navigationStart" && event.args?.data?.documentLoaderURL === url);
  if (!start) return { run, windows: [], note: "the trace has no navigation start of the page" };
  const at = (event: TraceEvent) => (event.ts - start.ts) / 1000;
  const thread = events
    .filter((event) => event.ph === "X" && event.pid === start.pid && event.tid === start.tid && event.dur !== undefined)
    .sort((a, b) => a.ts - b.ts || (b.dur ?? 0) - (a.dur ?? 0));
  // Self time: an event's own time less its direct children's.
  const self = new Map<TraceEvent, number>();
  const open_: TraceEvent[] = [];
  for (const event of thread) {
    while (open_.length && open_[open_.length - 1].ts + (open_[open_.length - 1].dur ?? 0) <= event.ts) open_.pop();
    const parent = open_[open_.length - 1];
    if (parent) self.set(parent, (self.get(parent) ?? 0) - (event.dur ?? 0));
    self.set(event, (self.get(event) ?? 0) + (event.dur ?? 0));
    open_.push(event);
  }
  const { marks } = run;
  const edges: [string, number, number][] = [
    ["1 files in", 0, run.parts["1 files in"]],
    ["2 scripts run", run.parts["1 files in"], marks.firstHostMessage],
    ["3+4 first commit and the bar", marks.firstHostMessage, marks.bar],
    ["5 bar painted", marks.bar, marks.barPainted],
  ];
  const windows = edges.map(([name, from, to]) => {
    const byName = new Map<string, number>();
    // An event counts in the part where it starts.
    for (const event of thread) {
      if (at(event) < from || at(event) >= to) continue;
      byName.set(event.name, (byName.get(event.name) ?? 0) + (self.get(event) ?? 0) / 1000);
    }
    const rows = [...byName.entries()].sort((a, b) => b[1] - a[1]);
    return {
      name,
      length: to - from,
      busy: rows.reduce((sum, row) => sum + row[1], 0),
      rows: rows.slice(0, 12).map(([event, ms]) => ({ event, ms })),
    };
  });
  return { run, windows };
}

function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const fixed = (value: number) => (Number.isFinite(value) ? value.toFixed(1) : "none");
const load = () => fs.readFileSync("/proc/loadavg", "utf8").trim();

async function main() {
  const { dist, out, runs, cache, probe, trace, oneProfile } = options(process.argv.slice(2));
  const server = await serve(dist, cache);
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/index.html`;
  const loadAtStart = load();
  const arms: Arm[] = [
    { way: "call", size: "empty" },
    { way: "document", size: "empty" },
    { way: "call", size: "session" },
    { way: "document", size: "session" },
  ];
  const report: Record<string, unknown> = {
    cache: cache ? "max-age=3600" : "no-store",
    runs,
    loadAtStart,
    contextBytes: {
      empty: Buffer.byteLength(JSON.stringify(context("empty"))),
      session: Buffer.byteLength(JSON.stringify(context("session"))),
    },
    arms: [],
  };
  let version = "";
  for (const arm of arms) {
    const json = JSON.stringify(context(arm.size));
    if (oneProfile) {
      const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cold-new-tab-page-"));
      const kept = await chromium.launchPersistentContext(profile, { headless: true, viewport: VIEWPORT });
      version = kept.browser()?.version() ?? version;
      const list: Run[] = [];
      for (let run = 0; run < runs; run++) {
        const { page, done } = await open(kept, arm, json);
        await page.goto(url, { waitUntil: "commit" });
        await done;
        list.push(await read(page));
        await page.close();
      }
      await kept.close();
      fs.rmSync(profile, { recursive: true, force: true });
      (report.arms as unknown[]).push({ arm, runs: list });
      console.log(`\narm: context by ${arm.way}, ${arm.size === "empty" ? "0 rows" : "826 workspaces"}, one profile`);
      for (const name of Object.keys(list[0].parts))
        console.log(
          `  ${name.padEnd(18)} by run: ${list.map((one) => fixed(one.parts[name as keyof typeof one.parts])).join(", ")}`,
        );
      continue;
    }
    // A new browser for each arm: its first page starts with a new profile and no cache.
    const browser = await chromium.launch({ headless: true });
    version = browser.version();
    const list: Run[] = [];
    for (let run = 0; run < runs; run++) {
      const { page, done } = await open(browser, arm, json);
      await page.goto(url, { waitUntil: "commit" });
      await done;
      list.push(await read(page));
      if (probe && run === 0) {
        fs.mkdirSync(probe, { recursive: true });
        await page.screenshot({ path: path.join(probe, `${arm.way}-${arm.size}.png`) });
      }
      await page.close();
    }
    const covered = await coverage(browser, url, arm, json);
    const split = trace ? await traced(browser, url, arm, json) : undefined;
    await browser.close();
    (report.arms as unknown[]).push({ arm, runs: list, coverage: covered, ...(split ? { trace: split } : {}) });
    const names = Object.keys(list[0].parts);
    console.log(`\narm: context by ${arm.way}, ${arm.size === "empty" ? "0 rows" : "826 workspaces"}`);
    for (const name of names) {
      const values = list.map((one) => one.parts[name as keyof typeof one.parts]);
      console.log(
        `  ${name.padEnd(18)} run 1 ${fixed(values[0]).padStart(8)} ms; p50 ${fixed(median(values)).padStart(8)} ms; longest ${fixed(Math.max(...values)).padStart(8)} ms`,
      );
    }
    const first = list[0];
    const before = first.resources.filter((entry) => entry.end <= first.marks.barPainted);
    const sum = (rows: { bytes: number }[]) => rows.reduce((total, row) => total + row.bytes, 0);
    const scripts = before.filter((entry) => entry.name.endsWith(".js"));
    const sheets = before.filter((entry) => entry.name.endsWith(".css"));
    console.log(
      `  loaded before the bar's frame (run 1): ${before.length} files, ${sum(before)} bytes: ${scripts.length} scripts ${sum(scripts)} bytes, ${sheets.length} sheets ${sum(sheets)} bytes`,
    );
    console.log(
      `  ran before the bar's frame (coverage run): scripts ${covered.scripts.reduce((total, row) => total + row.ran, 0)} of ${sum(covered.scripts)} bytes in ${covered.scripts.length} files; sheets ${covered.sheets.reduce((total, row) => total + row.ran, 0)} of ${sum(covered.sheets)} bytes`,
    );
    console.log(
      `  run 1 marks: ${Object.entries(first.marks)
        .sort((a, b) => a[1] - b[1])
        .map(([name, at]) => `${name} ${fixed(at)}`)
        .join(", ")}; paints: ${Object.entries(first.paints)
        .map(([name, at]) => `${name} ${fixed(at)}`)
        .join(", ")}`,
    );
    console.log(
      `  run 1 host calls: ${first.calls.map((call) => `${call.op.replace("cmux.agent.", "")}@${fixed(call.at)}`).join(", ")}`,
    );
    if (split) {
      console.log(
        `  traced run (slower: the trace is on): total ${fixed(split.run.parts.total)} ms${"note" in split ? `; ${split.note}` : ""}`,
      );
      for (const part of split.windows)
        console.log(
          `    ${part.name}: ${fixed(part.length)} ms long, main thread busy ${fixed(part.busy)} ms: ${part.rows
            .filter((row) => row.ms >= 1)
            .map((row) => `${row.event} ${fixed(row.ms)}`)
            .join(", ")}`,
        );
    }
    const errors = list.flatMap((one) => one.errors);
    if (errors.length) console.log(`  page errors: ${errors.length}: ${[...new Set(errors)].slice(0, 5).join(" | ")}`);
  }
  report.browser = `chromium ${version}`;
  report.loadAtEnd = load();
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, `${JSON.stringify(report, null, 1)}\n`);
  console.log(
    `\nbrowser: chromium ${version}; cache header: ${report.cache as string}; load average at the start: ${loadAtStart}; at the end: ${report.loadAtEnd as string}`,
  );
  console.log(
    `context bytes: 0 rows ${(report.contextBytes as { empty: number }).empty}; 826 workspaces ${(report.contextBytes as { session: number }).session}`,
  );
  server.close();
}

await main();
