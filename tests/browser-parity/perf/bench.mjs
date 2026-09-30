// Snapshot performance and output size on large pages, per tool.
//
//   node tests/browser-parity/perf/bench.mjs [--backend cmux-dev|cmux|aside|chrome]
//        [--pages stress|corpus|live|all|name,name] [--runs 5] [--label before]
//
// Backends:
//   cmux-dev  the Resources/browser-repl runtime in this process on Playwright
//             WebKit (lib/dev-driver.mjs).
//   cmux      a tagged app through its CLI: PARITY_CMUX_CLI and
//             CMUX_SOCKET_PATH, as run.mjs --backend cmux.
//   aside     `aside repl`, one one-shot call per page (never `aside exec`).
//   chrome    headless Google Chrome with a throwaway profile: Playwright's
//             `_snapshotForAI()` (Playwright MCP's snapshot) and the ChatGPT
//             for Chrome AX renderer from git history (compare/adapters.mjs).
//
// Every page gets one program: navigate, take `runs` full snapshots, change
// one element and take one more (the diff), resolve a ref, and for cmux read
// the ref table sizes after 100 snapshots of a page that replaces content.
// Results go to perf/results/<label>-<backend>.json; report.mjs renders them.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { createDevBrowser, createNodeHost, loadRuntime } from "../lib/dev-driver.mjs";
import { tokens } from "../compare/metrics.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const MARK = "@@PERF@@";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const backend = opt("backend", "cmux-dev");
const runs = Number(opt("runs", 5));
const label = opt("label", "run");
const pageSet = opt("pages", "stress,corpus");

// name -> { path (on PRIMARY) | url (live), settle ms, leak: run the ref-table check }
export const STRESS = {
  "cards-50k": { path: "/stress/stress.html?kind=cards&n=50000" },
  "cards-200k": { path: "/stress/stress.html?kind=cards&n=200000" },
  "table-10k": { path: "/stress/stress.html?kind=table&n=10000" },
  "list-5k": { path: "/stress/stress.html?kind=list&n=5000" },
  "deep-500": { path: "/stress/stress.html?kind=deep&n=500" },
  "deep-1k": { path: "/stress/stress.html?kind=deep&n=1000" },
  "iframes-300": { path: "/stress/stress.html?kind=iframes&n=300&peer={PEER}", settle: 1500 },
  "shadow-2k": { path: "/stress/stress.html?kind=shadow&n=2000" },
  "text-2m": { path: "/stress/stress.html?kind=text&n=2000000" },
  "select-5k": { path: "/stress/stress.html?kind=select&n=5000" },
  "virtual-100k": { path: "/stress/stress.html?kind=virtual&n=100000" },
};
export const CORPUS = ["wikipedia", "hackernews", "github", "mdn", "mdn-iframe", "npr", "bbc", "books", "vercel"];
export const LIVE = {
  "live-wikipedia-cities": "https://en.wikipedia.org/wiki/List_of_largest_cities",
  "live-github-pr-files": "https://github.com/manaflow-ai/cmux/pull/15570/files",
  "live-amazon-search": "https://www.amazon.com/s?k=usb+c+cable",
  "live-hn-thread": "https://news.ycombinator.com/item?id=49896586",
};

function selectPages(origins) {
  const out = [];
  const want = new Set(pageSet.split(","));
  const all = want.has("all");
  for (const [name, p] of Object.entries(STRESS)) {
    if (all || want.has("stress") || want.has(name)) out.push({ name, url: origins.primary + p.path.replace("{PEER}", encodeURIComponent(origins.peer)), settle: p.settle ?? 300 });
  }
  for (const name of CORPUS) {
    if (all || want.has("corpus") || want.has(name)) out.push({ name, url: `${origins.primary}/corpus/${name}.html`, settle: 300 });
  }
  for (const [name, url] of Object.entries(LIVE)) {
    if (all || want.has("live") || want.has(name)) out.push({ name, url: process.env[`PERF_URL_${name.replace(/-/g, "_").toUpperCase()}`] || url, settle: 3000, live: true });
  }
  return out;
}

// A small change the diff must find: the first heading's text, else the
// first button's, else a new paragraph.
const MUTATE_FN = `() => {
  const el = document.querySelector("h1, h2, h3, button");
  if (el) { el.textContent = el.textContent + " (changed)"; return "text"; }
  document.body.insertAdjacentHTML("afterbegin", "<p>perf change</p>");
  return "insert";
}`;
// As an expression for tools that evaluate strings; cmux passes the
// function, which a page's Content Security Policy does not block.
const MUTATE = `(${MUTATE_FN})()`;

// The cmux program: runs in the REPL (cmux-dev in this process, or the app).
function cmuxProgram(p) {
  return `
const __out = { name: ${JSON.stringify(p.name)}, runs: [] };
try {
  await page.setViewportSize({ width: 1280, height: 800 });
  const __t0 = Date.now();
  await page.goto(${JSON.stringify(p.url)}, { timeout: 90000 }).catch((e) => { if (!/timeout/i.test(String(e))) throw e; });
  __out.gotoMs = Date.now() - __t0;
  await page.waitForTimeout(${p.settle});
  for (let i = 0; i < ${runs}; i++) {
    const t = Date.now();
    const s = await snapshot();
    const snapMs = Date.now() - t;
    const tp = Date.now();
    const printed = String(s);
    const printMs = Date.now() - tp;
    __out.runs.push({ snapMs, printMs, timing: s._timing || null, treeChars: s.tree.length, printedChars: printed.length });
    if (i === 0) { __out.tree = s.tree; __out.printed = printed; }
  }
  await page.evaluate(${MUTATE_FN});
  {
    const t = Date.now();
    const s = await snapshot();
    const snapMs = Date.now() - t;
    const tp = Date.now();
    const printed = String(s);
    __out.diff = { snapMs, printMs: Date.now() - tp, timing: s._timing || null, diffChars: s.diff.length, printedChars: printed.length, usesDiff: s.usesDiff, printed: printed.slice(0, 4000) };
  }
  // Ref resolution: the last ref in the tree, through a locator.
  const refs = [...__out.tree.matchAll(/\\[ref=(\\w+)\\]/g)].map((m) => m[1]);
  __out.refCount = refs.length;
  const last = refs.filter((r) => !r.startsWith("f")).pop();
  if (last) {
    const t = Date.now();
    await page.locator(last).textContent({ timeout: 10000 }).catch(() => null);
    __out.locatorMs = Date.now() - t;
  }
  const stats = await page.mainFrame()._agent("stats").catch(() => null);
  __out.agentStats = stats;
} catch (e) {
  __out.error = String(e && (e.message + " | " + e.stack) || e);
}
console.log(${JSON.stringify(MARK)} + JSON.stringify(__out));`;
}

// 100 snapshots of a page whose content is replaced between them: the ref
// table must not grow without bound (refs of removed nodes are dropped).
function leakProgram(url) {
  return `
const __out = { name: "leak", sizes: [] };
try {
  await page.goto(${JSON.stringify(url)});
  for (let i = 0; i < 100; i++) {
    await page.evaluate((i) => { document.getElementById("root").innerHTML = Array.from({ length: 200 }, (_, j) => '<button>b' + i + '-' + j + '</button>').join(""); }, i);
    await snapshot();
    await page.locator("button").last().textContent();
    if (i % 10 === 9) __out.sizes.push(await page.mainFrame()._agent("stats"));
  }
  __out.heap = typeof process !== "undefined" && process.memoryUsage ? process.memoryUsage().heapUsed : null;
} catch (e) { __out.error = String(e && (e.message + " | " + e.stack) || e); }
console.log(${JSON.stringify(MARK)} + JSON.stringify(__out));`;
}

function parseMarked(text) {
  const line = text.split("\n").find((l) => l.startsWith(MARK));
  if (!line) throw new Error(`no result marker: ${text.slice(-800)}`);
  return JSON.parse(line.slice(MARK.length));
}

function runProcess(cmd, argv, { input, env, timeoutMs = 600_000 } = {}) {
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn(cmd, argv, { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, ...env } });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, out, err, ms: Date.now() - started });
    });
    child.stdin.end(input ?? "");
  });
}

// ---------------------------------------------------------------------------
// Backends

async function cmuxDevBackend() {
  const ns = loadRuntime();
  const browser = await createDevBrowser({ viewport: { width: 1280, height: 800 } });
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "perf-cmux-"));
  const session = () => {
    const lines = [];
    const driver = browser.driver();
    const host = createNodeHost({ workDir, sessionId: `perf-${Date.now()}`, print: (_l, t) => lines.push(t) });
    const repl = ns.replHost.createBrowserRepl({ host, driver });
    return {
      lines,
      async eval(code) {
        lines.length = 0;
        const t = Date.now();
        // No output cap: the result marker line is large.
        const r = await repl.evaluate(code, { maxOutput: 0 });
        return { ok: r.ok, error: r.error, text: lines.join("\n"), ms: Date.now() - t };
      },
      async close() {
        repl.dispose();
        await driver.detach().catch(() => {});
      },
    };
  };
  return {
    async page(p) {
      const s = session();
      try {
        const heap0 = process.memoryUsage().heapUsed;
        const r = await s.eval(cmuxProgram(p));
        if (!r.ok) throw new Error(r.error);
        const out = parseMarked(r.text);
        out.hostHeapDelta = process.memoryUsage().heapUsed - heap0;
        return out;
      } finally {
        await s.close();
      }
    },
    async overhead() {
      const s = session();
      try {
        await s.eval("1");
        const times = [];
        for (let i = 0; i < 20; i++) times.push((await s.eval("1")).ms);
        return times;
      } finally {
        await s.close();
      }
    },
    async leak(url) {
      const s = session();
      try {
        const r = await s.eval(leakProgram(url));
        return parseMarked(r.text);
      } finally {
        await s.close();
      }
    },
    close: async () => {
      await browser.close();
      fs.rmSync(workDir, { recursive: true, force: true });
    },
  };
}

function cmuxAppBackend() {
  const cli = process.env.PARITY_CMUX_CLI;
  if (!cli || !process.env.CMUX_SOCKET_PATH) throw new Error("cmux backend needs PARITY_CMUX_CLI and CMUX_SOCKET_PATH");
  const call = (code, session) => runProcess(cli, ["browser", "repl", ...(session ? ["--session", session] : []), "--timeout", "600000", "--max-output", "0", "--eval", "-"], { input: code });
  return {
    // A session per page, as the dev backend does: the first snapshot of a
    // page must not diff against the previous page's tree.
    async page(p) {
      const session = `perf-${process.pid}-${p.name}`;
      try {
        const r = await call(cmuxProgram(p), session);
        if (!r.out.includes(MARK)) throw new Error(`exit ${r.code} after ${r.ms}ms: ${(r.err || r.out).slice(-600)}`);
        return parseMarked(r.out);
      } finally {
        await runProcess(cli, ["browser", "repl", "reset", session]);
      }
    },
    async overhead() {
      const s = `perf-oh-${process.pid}`;
      await call("1", s);
      const times = [];
      for (let i = 0; i < 20; i++) {
        const r = await call("1", s);
        const m = /\[ok \| (\d+)ms\]/.exec(r.out);
        times.push({ wall: r.ms, inApp: m ? Number(m[1]) : null });
      }
      await runProcess(cli, ["browser", "repl", "reset", s]);
      return times;
    },
    async leak(url) {
      const r = await call(leakProgram(url), `perf-leak-${process.pid}`);
      return parseMarked(r.out);
    },
    close: async () => {
      await runProcess(cli, ["browser", "repl", "reset", `perf-leak-${process.pid}`]);
    },
  };
}

// Aside: one one-shot `aside repl` call per page, in its own tab.
function asideBackend() {
  const program = (p) => `
const __out = { name: ${JSON.stringify(p.name)}, runs: [] };
const __tab = await openTab(${JSON.stringify(p.url)});
try {
  await sleep(${p.settle});
  for (let i = 0; i < ${runs}; i++) {
    const t = Date.now();
    const s = await snapshot(page);
    __out.runs.push({ snapMs: Date.now() - t, treeChars: s.tree.length });
    if (i === 0) __out.tree = s.tree;
  }
  await page.evaluate(${JSON.stringify(MUTATE)});
  {
    const t = Date.now();
    const s = await snapshot(page);
    __out.diff = { snapMs: Date.now() - t, diffChars: (s.diff || "").length, printed: String(s.diff || "").slice(0, 4000) };
  }
  const refs = [...__out.tree.matchAll(/\\[ref=(\\w+)\\]/g)].map((m) => m[1]).filter((r) => !r.startsWith("f"));
  __out.refCount = refs.length;
  const last = refs.pop();
  if (last) {
    const t = Date.now();
    await page.locator(last).textContent({ timeout: 10000 }).catch(() => null);
    __out.locatorMs = Date.now() - t;
  }
} catch (e) { __out.error = String(e && (e.message + " | " + e.stack) || e); }
finally { await closeTab(__tab).catch(() => {}); }
console.log(${JSON.stringify(MARK)} + JSON.stringify(__out));`;
  return {
    async page(p) {
      const r = await runProcess("aside", ["repl", program(p)], { timeoutMs: 900_000 });
      if (!r.out.includes(MARK)) throw new Error(`aside exit ${r.code} after ${r.ms}ms: ${(r.err || r.out).slice(-400)}`);
      return parseMarked(r.out);
    },
    async overhead() {
      const times = [];
      for (let i = 0; i < 10; i++) times.push((await runProcess("aside", ["repl", "1"])).ms);
      return times;
    },
    async leak() {
      return null;
    },
    close: async () => {},
  };
}

// Headless Chrome: Playwright's AI snapshot (Playwright MCP) and the ChatGPT
// for Chrome AX renderer, each timed in this process.
async function chromeBackend() {
  const { createChromeReferences } = await import("./chrome-refs.mjs");
  return createChromeReferences({ runs, mutate: MUTATE });
}

// ---------------------------------------------------------------------------

function summarize(result) {
  if (!result || result.error || !result.runs) return result;
  const ms = result.runs.map((r) => r.snapMs).sort((a, b) => a - b);
  const pct = (q) => ms[Math.min(ms.length - 1, Math.ceil(q * ms.length) - 1)];
  const text = result.printed ?? result.tree ?? "";
  const t = result.runs.slice(1).map((r) => r.timing).filter(Boolean);
  const avg = (k) => (t.length ? t.reduce((a, x) => a + (x[k] || 0), 0) / t.length : null);
  return Object.assign(result, {
    p50: pct(0.5),
    p95: pct(0.95),
    firstMs: result.runs[0]?.snapMs,
    treeBytes: Buffer.byteLength(result.tree ?? ""),
    printedBytes: Buffer.byteLength(text),
    printedChars: text.length,
    treeChars: (result.tree ?? "").length,
    printedTokens: tokens(text),
    treeTokens: tokens(result.tree ?? ""),
    breakdown: t.length ? { agentMs: avg("agentMs"), transportMs: avg("callMs") - avg("agentMs"), hostMs: avg("totalMs") - avg("callMs"), diffMs: avg("diffMs"), frames: t[0].frames } : null,
  });
}

async function main() {
  const servers = await startFixtureServers();
  const make = { "cmux-dev": cmuxDevBackend, cmux: cmuxAppBackend, aside: asideBackend, chrome: chromeBackend }[backend];
  if (!make) throw new Error(`unknown backend ${backend}`);
  const b = await make();
  const pages = selectPages(servers.origins);
  const results = { backend, label, runs, date: new Date().toISOString(), host: os.hostname(), pages: {} };
  const outFile = path.join(here, "results", `${label}-${backend}.json`);
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  const save = () => {
    const slim = JSON.parse(JSON.stringify(results));
    const trim = (r) => {
      if (!r) return;
      delete r.tree;
      if (r.printed) r.printed = r.printed.slice(0, 2000);
      if (r.diff && r.diff.printed) r.diff.printed = r.diff.printed.slice(0, 2000);
      for (const v of Object.values(r.tools || {})) trim(v);
    };
    for (const r of Object.values(slim.pages)) trim(r);
    fs.writeFileSync(outFile, JSON.stringify(slim, null, 1));
  };
  try {
    for (const p of pages) {
      const t = Date.now();
      let r;
      try {
        r = summarize(await b.page(p));
      } catch (e) {
        r = { name: p.name, error: String(e.message || e).slice(0, 2000) };
      }
      const byTool = r && r.tools ? r.tools : { [backend]: r };
      for (const [tool, v] of Object.entries(byTool)) {
        if (v && v !== r) summarize(v);
        const line = v?.error ? `ERROR ${v.error.split("\n")[0].slice(0, 200)}` : `p50 ${v.p50}ms p95 ${v.p95}ms first ${v.firstMs}ms tree ${v.treeBytes}B ${v.treeTokens}tok printed ${v.printedBytes}B diff ${v.diff?.snapMs}ms/${v.diff?.diffChars}ch locator ${v.locatorMs}ms` + (v.breakdown ? ` [agent ${v.breakdown.agentMs.toFixed(0)} transport ${v.breakdown.transportMs.toFixed(0)} host ${v.breakdown.hostMs.toFixed(0)} diff ${v.breakdown.diffMs.toFixed(0)}]` : "");
        console.log(`${p.name.padEnd(22)} ${tool.padEnd(10)} ${line} (${Date.now() - t}ms)`);
      }
      results.pages[p.name] = r;
      save();
    }
    if (!args.includes("--no-overhead")) {
      results.overhead = await b.overhead();
      console.log("per-call overhead", JSON.stringify(results.overhead));
    }
    if (!args.includes("--no-leak")) {
      results.leak = await b.leak(`${servers.origins.primary}/stress/stress.html?kind=cards&n=60`);
      console.log("ref tables over 100 snapshots", JSON.stringify(results.leak));
    }
    save();
    console.log(`wrote ${path.relative(process.cwd(), outFile)}`);
  } finally {
    await b.close();
    await servers.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
