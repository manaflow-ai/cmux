#!/usr/bin/env node
// Head-to-head comparison of agent page representations on the same pages.
// See docs/browser-repl/representation-comparison.md.
//
//   ./tests/browser-parity/compare/setup.sh            # once: npm deps + browser-use venv
//   node tests/browser-parity/compare/run.mjs [--pages fixtures,nest,live] [--only NAME]
//        [--skip-tools aside,browser-use,stagehand] [--no-scenarios]
//
// Writes results/results.json (metrics), results/raw/<page>/<tool>.txt for local
// pages, results/raw-live/ for live sites (gitignored), and results/summary.md.
import fs from "node:fs";
import http from "node:http";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { startFixtureServers } from "../lib/fixture-server.mjs";
import { createCmuxAdapter, createAsideAdapter, createChromeAdapter, createBrowserUseAdapter, createStagehandAdapter } from "./adapters.mjs";
import { tokens, TOKENIZER, scoreRecall, scorePrecision, parseItems, norm } from "./metrics.mjs";
import { scoreStructure, focusProbe } from "./probes.mjs";
import { writeSummary } from "./report.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
export const TOOLS = ["cmux", "cmux-i", "cmux-v", "aside", "aside-i", "chatgpt-ax", "chatgpt-dom", "chatgpt-pw", "chatgpt-live-ax", "chatgpt-live-dom", "chatgpt-live-pw", "pw-mcp", "browser-use", "stagehand"];
// Captured by chatgpt-live.ts in the user's Chrome; read from its output.
const LIVE_TOOLS = ["chatgpt-live-ax", "chatgpt-live-dom", "chatgpt-live-pw"];
const CORPUS = fs.readdirSync(path.join(here, "../fixtures/corpus")).filter((f) => f.endsWith(".html")).map((f) => f.replace(/\.html$/, ""));
// The frozen corpus pages link images and fonts on their original sites;
// every tool, and the live ChatGPT capture, loads them with the same policy.
const CORPUS_CSP = "default-src 'self' 'unsafe-inline' data:; img-src 'self' data:";

const FIXTURES = ["index", "aria", "states", "frames", "frame-inner", "shadow", "surface", "dynamic", "input", "dialogs", "files"];
const LIVE = {
  wikipedia: "https://en.wikipedia.org/wiki/WebKit",
  hn: "https://news.ycombinator.com",
  github: "https://github.com/manaflow-ai/cmux",
  mdn: "https://developer.mozilla.org/en-US/docs/Web/API/Element/click",
  amazon: "https://www.amazon.com/s?k=usb+c+cable",
  vercel: "https://vercel.com",
};

function parseArgs(argv) {
  const a = { pages: ["fixtures", "nest", "corpus", "live"], only: null, skip: new Set(), scenarios: true };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--pages") a.pages = argv[++i].split(",");
    else if (argv[i] === "--only") a.only = argv[++i];
    else if (argv[i] === "--skip-tools") a.skip = new Set(argv[++i].split(","));
    else if (argv[i] === "--no-scenarios") a.scenarios = false;
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  return a;
}

// The nested-frame pages (copied from the frame investigation) link
// localhost:8811 and 127.0.0.1:8812 by absolute URL; they are served on
// 18811/18812 with those URLs rewritten, alternating origins at every level.
function serveNest() {
  const dir = path.join(here, "pages");
  const mk = (port, host) =>
    new Promise((resolve) => {
      const s = http.createServer((req, res) => {
        const pathname = new URL(req.url, "http://x").pathname;
        // Frozen copies of live pages (see freezePage), kept out of git.
        if (pathname.startsWith("/static/")) {
          const f = path.join(here, "results/raw-live", path.basename(pathname));
          if (!fs.existsSync(f)) return res.writeHead(404).end();
          return res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(fs.readFileSync(f));
        }
        if (pathname.startsWith("/corpus/")) {
          const f = path.join(here, "../fixtures/corpus", path.basename(pathname));
          if (!fs.existsSync(f)) return res.writeHead(404).end();
          return res.writeHead(200, { "content-type": "text/html; charset=utf-8", "content-security-policy": CORPUS_CSP }).end(fs.readFileSync(f));
        }
        const f = path.join(dir, path.basename(pathname) || "top.html");
        if (!fs.existsSync(f)) return res.writeHead(404).end();
        const html = fs.readFileSync(f, "utf8").replaceAll("localhost:8811", "localhost:18811").replaceAll("127.0.0.1:8812", "127.0.0.1:18812");
        res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }).end(html);
      });
      s.listen(port, host, () => resolve(s));
    });
  return Promise.all([mk(18811, "127.0.0.1"), mk(18812, "127.0.0.1")]).then((servers) => ({
    url: "http://localhost:18811/top.html",
    big: "http://localhost:18811/big.html",
    close: () => Promise.all(servers.map((s) => new Promise((r) => s.close(r)))),
  }));
}

const ACT = `(() => { const e = document.getElementById("email"); e.focus(); e.value = "me@x.com"; e.dispatchEvent(new Event("input", { bubbles: true })); e.dispatchEvent(new Event("change", { bubbles: true })); document.getElementById("tos").click(); return 1; })()`;
const REF_SETUP = `(() => { document.body.innerHTML = '<ul id=L><li><button id=a>Alpha</button></li><li><button id=b>Beta</button></li></ul><button id=out onclick="this.textContent=\\'Out clicked\\'">Out</button>'; return 1; })()`;
// Two insertions before the survivors and one removal, so position-based
// numbering would shift every survivor.
const REF_MUTATE = `(() => { document.getElementById("b").textContent = "Beta renamed"; document.getElementById("L").insertAdjacentHTML("afterbegin", "<li><button>Zero</button></li><li><button>Minus</button></li>"); document.getElementById("a").closest("li").remove(); return 1; })()`;

const safe = (s) => s.replace(/[^\w.-]+/g, "_");

async function runAll(adapters, url, steps, settleMs, log) {
  const merged = steps.map(() => ({}));
  const meta = { errors: {}, versions: {} };
  for (const a of adapters) {
    const t0 = Date.now();
    try {
      let r = await a.run(url, steps, { settleMs });
      if (a.name === "chrome") {
        meta.groundTruth = r.groundTruth;
        meta.finalUrl = r.finalUrl;
        meta.title = r.title;
        r = r.results;
      } else if (r && r.results) {
        meta.versions[a.name] = r.version;
        r = r.results;
      }
      r.forEach((x, i) => x && Object.assign(merged[i], x));
      log(`    ${a.name} ${Date.now() - t0}ms`);
    } catch (e) {
      meta.errors[a.name] = String(e.message || e).split("\n")[0].slice(0, 300);
      log(`    ${a.name} FAILED ${meta.errors[a.name]}`);
    }
  }
  return { steps: merged, meta };
}

// A capture of a different document than the one the others saw: a bot wall
// (headless WebKit and browser-use's Chrome on Amazon) or a signed-in
// redirect (Aside Browser uses the person's own profile).
const BLOCKED = /Sorry! Something went wrong|Robot Check|Enter the characters you see|captcha|Access Denied|Just a moment\.\.\./i;
function validity(text, requested, chromeTitle) {
  if (!text) return null;
  if (BLOCKED.test(text) && !BLOCKED.test(chromeTitle ?? "")) return "blocked";
  const m = /^(?:- title: .*\[url=|url: )(\S+?)\]?$/m.exec(text);
  if (m) {
    try {
      const a = new URL(m[1]);
      const b = new URL(requested);
      if (a.host !== b.host || a.pathname.replace(/\/$/, "") !== b.pathname.replace(/\/$/, "")) return `redirected to ${a.host}${a.pathname.split("/").slice(0, 2).join("/")}/…`;
    } catch {}
  }
  return null;
}

async function freezePage(url, file) {
  const { loadPlaywright } = await import("../lib/dev-driver.mjs");
  const { DESKTOP_UA, VIEWPORT } = await import("./adapters.mjs");
  const browser = await loadPlaywright().chromium.launch({ channel: "chrome", headless: true });
  try {
    const page = await (await browser.newContext({ viewport: VIEWPORT, userAgent: DESKTOP_UA })).newPage();
    await page.goto(url, { waitUntil: "load", timeout: 60_000 });
    await page.waitForTimeout(2500);
    const html = await page.evaluate((base) => {
      for (const s of document.querySelectorAll("script, noscript, link[rel=preload], link[rel=prefetch]")) s.remove();
      const b = document.createElement("base");
      b.href = base;
      document.head.prepend(b);
      return "<!doctype html>\n" + document.documentElement.outerHTML;
    }, new URL(url).origin + "/");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, html);
  } finally {
    await browser.close();
  }
}

// Refs a tool gives to named buttons in the ref-stability page.
function refOf(tool, text, name) {
  const { items } = parseItems(tool, text);
  const key = norm(name);
  const hits = items.filter((it) => ` ${norm(it.block)} `.includes(` ${key} `) && !(key === "beta" && norm(it.block).includes("beta renamed")));
  hits.sort((a, b) => norm(a.block).length - norm(b.block).length);
  return hits[0]?.ref ?? null;
}

function changeMetrics(tool, before, after) {
  if (!before?.text || !after?.text) return null;
  const inc = {
    cmux: after.printed,
    "cmux-i": after.printed,
    aside: after.incremental,
    "aside-i": after.incremental,
    "chatgpt-ax": after.incremental,
    "pw-mcp": after.incremental,
  }[tool];
  const shown = inc ?? after.text;
  const lines = shown.split("\n");
  const checkLine = lines.findLast((l) => /accept terms/i.test(l) || /id=tos/.test(l)) ?? "";
  const checkIdx = lines.indexOf(checkLine);
  const near = lines.slice(Math.max(0, checkIdx - 1), checkIdx + 2).join(" ");
  return {
    mode: inc != null ? "diff" : "full",
    fullBytes: Buffer.byteLength(after.text),
    shownBytes: Buffer.byteLength(shown),
    shownTokens: tokens(shown),
    ratio: Buffer.byteLength(shown) / Buffer.byteLength(after.text),
    showsValue: /me@x\.com/.test(shown),
    showsChecked: checkIdx >= 0 && /\bchecked\b(?!=false)(?!"?=?"?false)|checked=true|Value: 1\b|\[checked\]|\(checked\)/i.test(near) && !/checked=false/.test(near),
    markedChanges: (shown.match(/^\s*[~+-]|^\s*\*\[|\(changed\)|\[changed\]/gm) || []).length,
    lines: lines.length,
    excerpt: shown.length > 900 ? shown.slice(0, 900) + "\n…" : shown,
    afterText: after.text,
  };
}

function refMetrics(tool, c1, c2, resolved) {
  if (!c1?.text || !c2?.text) return null;
  const r1 = { Alpha: refOf(tool, c1.text, "Alpha"), Beta: refOf(tool, c1.text, "Beta"), Out: refOf(tool, c1.text, "Out") };
  const r2 = { Zero: refOf(tool, c2.text, "Zero"), Minus: refOf(tool, c2.text, "Minus"), "Beta renamed": refOf(tool, c2.text, "Beta renamed"), Out: refOf(tool, c2.text, "Out") };
  if (!r1.Beta && !r1.Out) return { addressable: false, r1, r2 };
  const back = Object.fromEntries(Object.entries(r1).map(([k, v]) => [v, k]));
  const rebound = [];
  for (const [name, ref] of Object.entries(r2)) {
    const was = back[ref];
    const expect = name === "Beta renamed" ? "Beta" : name === "Out" ? "Out" : null;
    if (ref && was && was !== expect) rebound.push(`${ref}: ${was} -> ${name}`);
  }
  return {
    addressable: true,
    r1,
    r2,
    survivorsKeepRef: r1.Beta === r2["Beta renamed"] && r1.Out === r2.Out,
    removedRefReused: rebound.length > 0,
    rebound,
    oldRefsAfterNewSnapshot: resolved ?? null,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const T0 = Date.now();
  const log = (s) => console.log(process.env.CMP_DEBUG ? `[${((Date.now() - T0) / 1000).toFixed(1)}s] ${s}` : s);
  const server = await startFixtureServers({ primaryPort: 18765, peerPort: 18766 });
  const nest = await serveNest();
  const adapters = [];
  const versions = {};
  try {
    adapters.push(await createChromeAdapter());
    log("adapters: chrome ready");
    if (!args.skip.has("cmux")) adapters.push(await createCmuxAdapter());
    if (!args.skip.has("aside")) adapters.push(createAsideAdapter());
    const bu = createBrowserUseAdapter();
    if (!args.skip.has("browser-use") && bu.available) adapters.push(bu);
    const sh = await createStagehandAdapter();
    if (!args.skip.has("stagehand") && sh.available) {
      adapters.push(sh);
      versions.stagehand = sh.version;
    }
    log("adapters ready");
    const pages = [];
    if (args.pages.includes("fixtures")) for (const f of FIXTURES) pages.push({ name: f, kind: "fixture", url: `${server.origins.primary}/${f === "index" ? "" : f + ".html"}?peer=${encodeURIComponent(server.origins.peer)}` });
    if (args.pages.includes("nest")) pages.push({ name: "nest", kind: "fixture", url: nest.url });
    if (args.pages.includes("corpus")) for (const c of CORPUS) pages.push({ name: `corpus-${c}`, kind: "corpus", url: `http://localhost:18811/corpus/${c}.html` });
    if (args.pages.includes("live")) for (const [name, url] of Object.entries(LIVE)) pages.push({ name, kind: "live", url });
    // Amazon refuses Playwright WebKit (the cmux dev driver), so a frozen copy
    // of the page Chrome received, scripts removed, is served locally to every
    // tool. Same markup and CSS, no bot wall.
    if (args.pages.includes("live") || args.pages.includes("frozen")) {
      if (!args.only || args.only === "amazon-frozen") {
        await freezePage(LIVE.amazon, path.join(here, "results/raw-live/amazon-frozen.html"));
        pages.push({ name: "amazon-frozen", kind: "live", url: "http://localhost:18811/static/amazon-frozen.html" });
      }
    }
    const selected = pages.filter((p) => !args.only || p.name === args.only);

    const resultsPath = path.join(here, "results/results.json");
    const results = fs.existsSync(resultsPath) ? JSON.parse(fs.readFileSync(resultsPath, "utf8")) : { pages: {}, scenarios: {} };
    results.tokenizer = TOKENIZER;
    results.cmuxRuntime = cmuxRuntimeId();
    results.viewport = "1280x800";

    for (const p of selected) {
      log(`${p.name} ${p.url}`);
      const startedAt = new Date().toISOString();
      const settleMs = p.kind === "live" ? 2500 : p.kind === "corpus" ? 1200 : 500;
      // The third capture is cmux's viewport scope (cmux-v); the other tools
      // have none and take it as a repeat of the full capture.
      const { steps, meta } = await runAll(adapters, p.url, [{ op: "capture", mode: "full" }, { op: "capture", mode: "interactive" }, { op: "capture", mode: "viewport" }], settleMs, log);
      Object.assign(versions, meta.versions);
      const outputs = { ...steps[2], ...steps[0], ...steps[1], ...readLive(p.name) };
      const rawDir = path.join(here, p.kind === "live" ? "results/raw-live" : "results/raw", safe(p.name));
      fs.mkdirSync(rawDir, { recursive: true });
      const gt = meta.groundTruth;
      if (gt) fs.writeFileSync(path.join(rawDir, "ground-truth.json"), JSON.stringify(gt, null, 1));
      const page = { url: p.url, kind: p.kind, startedAt, finishedAt: new Date().toISOString(), title: meta.title, errors: meta.errors, groundTruth: gt ? summarizeGt(gt) : null, tools: {} };
      for (const tool of TOOLS) {
        const o = outputs[tool];
        if (!o) continue;
        if (o.error) {
          page.tools[tool] = { error: o.error };
          continue;
        }
        fs.writeFileSync(path.join(rawDir, `${tool}.txt`), o.text ?? "");
        const entry = { bytes: Buffer.byteLength(o.text ?? ""), tokens: tokens(o.text ?? ""), ms: o.ms ?? null };
        if (gt) {
          const r = scoreRecall(tool, o.text, gt);
          const rv = scoreRecall(tool, o.text, gt, { viewportOnly: true });
          const pr = scorePrecision(tool, o.text, gt);
          entry.recall = { strict: r.strict, lenient: r.lenient, mentioned: r.mentioned, denominator: r.denominator, unnamed: r.unnamed, misses: r.misses };
          entry.recallViewport = { lenient: rv.lenient, denominator: rv.denominator };
          entry.addressableItems = r.items.length;
          entry.precision = pr;
        }
        const invalid = validity(o.text, p.url, meta.title);
        if (invalid) entry.invalid = invalid;
        page.tools[tool] = entry;
      }
      if (p.kind === "fixture") page.structure = scoreStructure(p.name, outputs);
      results.pages[p.name] = page;
      fs.writeFileSync(resultsPath, JSON.stringify(results, null, 1));
    }

    if (args.scenarios && !args.only) {
      const url = `${server.origins.primary}/?peer=${encodeURIComponent(server.origins.peer)}`;
      for (const [key, pageUrl] of [["change", url], ["changeBig", nest.big]]) {
        // One run per mode: Aside diffs against whatever snapshot came
        // last, so interleaving full and interactive captures would be unfair.
        results.scenarios[key] = {};
        const runs = {};
        for (const mode of ["full", "interactive"]) {
          log(`scenario: change reporting (${key}, ${mode})`);
          runs[mode] = await runAll(adapters, pageUrl, [{ op: "capture", mode }, { op: "eval", js: ACT }, { op: "capture", mode }], 500, log);
        }
        for (const tool of TOOLS) {
          const ch = runs[/-i$/.test(tool) ? "interactive" : "full"];
          const before = ch.steps[0][tool];
          const after = ch.steps[2][tool];
          const m = changeMetrics(tool, before, after);
          if (m) {
            const { afterText, ...rest } = m;
            results.scenarios[key][tool] = { ...rest, focused: focusProbe(tool, afterText) };
          }
        }
      }
      log("scenario: ref stability");
      const rs = await runAll(adapters, url, [{ op: "eval", js: REF_SETUP }, { op: "capture", mode: "full" }, { op: "capture", mode: "interactive" }, { op: "eval", js: REF_MUTATE }, { op: "capture", mode: "full" }, { op: "capture", mode: "interactive" }, { op: "resolve", from: 1, names: ["Alpha", "Beta", "Out"] }], 500, log);
      results.scenarios.refs = {};
      for (const tool of TOOLS) {
        const interactive = /-i$/.test(tool);
        const c1 = rs.steps[interactive ? 2 : 1][tool];
        const c2 = rs.steps[interactive ? 5 : 4][tool];
        const resolved = interactive ? null : rs.steps[6]?.[tool]?.resolve ?? null;
        const m = refMetrics(tool, c1, c2, resolved);
        if (m) results.scenarios.refs[tool] = { ...m, before: c1.text, after: c2.text };
      }
    }
    if (args.scenarios && !args.only) {
      // Fill, check and submit with each tool's own locators, then what the
      // tool prints next. The live ChatGPT flow (by AX index) is read from
      // chatgpt-live.ts's output.
      log("scenario: action flow");
      const url = `${server.origins.primary}/?peer=${encodeURIComponent(server.origins.peer)}`;
      const ACTIONS = [{ fill: "#email", value: "me@x.com" }, { click: "#tos" }, { click: "#submit" }];
      results.scenarios.actionFlow = {};
      for (const mode of ["full", "interactive"]) {
        const run = await runAll(adapters.filter((a) => ["chrome", "cmux", "aside"].includes(a.name)), url, [{ op: "capture", mode }, { op: "act", actions: ACTIONS }, { op: "capture", mode }], 500, log);
        for (const tool of TOOLS) {
          if (/-i$/.test(tool) !== (mode === "interactive")) continue;
          const m = flowMetrics(tool, run.steps[0][tool], run.steps[2][tool]);
          if (m) results.scenarios.actionFlow[tool] = m;
        }
      }
      const live = readLiveScenarios();
      if (live?.actionFlow) {
        const f = live.actionFlow;
        results.scenarios.actionFlow["chatgpt-live-ax"] = { ...flowMetrics("chatgpt-live-ax", { text: f.before }, { text: f.afterFull, incremental: f.after }), actionErrors: Object.fromEntries(Object.entries(f).filter(([k]) => k.endsWith("error"))), submittedText: f.page };
      }
      if (live?.refs) {
        const r = live.refs;
        results.scenarios.refs["chatgpt-live-ax"] = { ...refMetrics("chatgpt-live-ax", { text: r.before }, { text: r.after }, { Alpha: { error: r.oldAlpha }, Out: { text: r.oldOut } }), before: r.before, after: r.after };
      }
      if (live) results.chatgptLive = { capturedAt: live.capturedAt, approvals: { ax: live["approvals-ax"], legacy: live["approvals-legacy"] } };
    }
    results.offlineVsLive = offlineVsLive(results);
    results.versions = { ...(results.versions ?? {}), ...versions };
    fs.writeFileSync(resultsPath, JSON.stringify(results, null, 1));
    writeSummary(results, path.join(here, "results/summary.md"));
    log(`wrote ${path.relative(process.cwd(), resultsPath)} and results/summary.md`);
  } finally {
    for (const a of adapters) {
      const t0 = Date.now();
      await a.close?.().catch(() => {});
      if (process.env.CMP_DEBUG) log(`closed ${a.name} ${Date.now() - t0}ms`);
    }
    // Browsers keep idle keep-alive connections open; closing would wait for
    // them, and the process exits right after.
    void server.close();
    void nest.close();
  }
}

// The user's Chrome runs the React Scan extension, which adds a "React Not
// Detected" toast to every page after a moment; ChatGPT reads it like page
// content. It is not the page's, so it is removed before scoring.
export function stripExtensionUi(text) {
  return text.replace(/^(\t*)\d+ container react-scan-toast\n[\s\S]*?react-scan-toast-close-button\n\1\t\t\d+ image\n?/m, "");
}

function readLive(page) {
  const dir = path.join(here, "results/chatgpt-live", page);
  const out = {};
  for (const tool of LIVE_TOOLS) {
    const f = path.join(dir, `${tool}.txt`);
    if (!fs.existsSync(f)) continue;
    const text = fs.readFileSync(f, "utf8");
    out[tool] = text.startsWith("ERROR: ") ? { error: text.slice(7) } : { text: stripExtensionUi(text) };
  }
  return out;
}

function readLiveScenarios() {
  const f = path.join(here, "results/chatgpt-live/scenarios.json");
  if (!fs.existsSync(f)) return null;
  const d = JSON.parse(fs.readFileSync(f, "utf8"));
  for (const sc of [d.actionFlow, d.refs]) if (sc) for (const k of ["before", "after", "afterFull"]) if (typeof sc[k] === "string") sc[k] = stripExtensionUi(sc[k]);
  return d;
}

function flowMetrics(tool, before, after) {
  if (!before?.text || !after?.text) return null;
  const inc = { cmux: after.printed, "cmux-i": after.printed, aside: after.incremental, "aside-i": after.incremental, "chatgpt-ax": after.incremental, "chatgpt-live-ax": after.incremental, "pw-mcp": after.incremental }[tool];
  if (inc === undefined) return null;
  const shown = inc ?? after.text;
  return {
    fullBytes: Buffer.byteLength(after.text),
    shownBytes: Buffer.byteLength(shown),
    shownTokens: tokens(shown),
    showsValue: /me@x\.com/.test(shown),
    showsChecked: /accept terms[^\n]*(\[checked\]|Value: 1)|(\[checked\]|checked=true)[^\n]*accept terms/i.test(shown),
    showsSubmitResult: /Submitted/.test(shown),
    excerpt: shown.length > 1500 ? shown.slice(0, 1500) + "\n…" : shown,
  };
}

// How the offline stand-ins (renderer on a clean-room snapshot, spec
// reproductions) differ from the live runtime on the same page. URLs,
// ports and tab ids are normalized first.
function offlineVsLive(results) {
  const pairs = [["chatgpt-ax", "chatgpt-live-ax"], ["chatgpt-dom", "chatgpt-live-dom"], ["chatgpt-pw", "chatgpt-live-pw"]];
  // AX ids are compared apart from their numbers: the live service keeps one
  // id space per tab across navigations, so a reused tab starts above 0.
  const normText = (t) => t.replace(/Browser tab: \d+/g, "Browser tab: N").replace(/(localhost|127\.0\.0\.1):\d+/g, "HOST").replace(/%3A\d+/g, "%3APORT").replace(/^([~+]?\t*)\d+ /gm, "$1# ").replace(/UI element is \d+ /, "UI element is # ").replace(/node_id=\d+/g, "node_id=#").split("\n").map((l) => l.replace(/\s+$/, ""));
  const out = {};
  for (const [name, p] of Object.entries(results.pages)) {
    if (p.kind === "live") continue;
    const dir = path.join(here, "results/raw", safe(name));
    const liveDir = path.join(here, "results/chatgpt-live", name);
    for (const [off, live] of pairs) {
      const a = path.join(dir, `${off}.txt`);
      const b = path.join(liveDir, `${live}.txt`);
      if (!fs.existsSync(a) || !fs.existsSync(b)) continue;
      const A = normText(fs.readFileSync(a, "utf8"));
      const B = normText(stripExtensionUi(fs.readFileSync(b, "utf8")));
      const setA = new Map();
      for (const l of A) setA.set(l, (setA.get(l) ?? 0) + 1);
      let common = 0;
      for (const l of B) if (setA.get(l) > 0) {
        common++;
        setA.set(l, setA.get(l) - 1);
      }
      (out[name] ??= {})[off] = { offlineBytes: Buffer.byteLength(A.join("\n")), liveBytes: Buffer.byteLength(B.join("\n")), offlineLines: A.length, liveLines: B.length, sameLines: common, identical: A.join("\n") === B.join("\n") };
    }
  }
  return out;
}

// The cmux runtime measured: HEAD plus a digest of the runtime files, which
// may carry uncommitted changes.
function cmuxRuntimeId() {
  const root = path.resolve(here, "../../..");
  const dir = path.join(root, "Resources/browser-repl");
  const h = crypto.createHash("sha256");
  for (const f of ["snapshot.js", "page-agent.js", "api.js", "runtime-core.js"]) h.update(fs.readFileSync(path.join(dir, f)));
  const git = (...a) => execFileSync("git", ["-C", root, ...a], { encoding: "utf8" }).trim();
  return { head: git("rev-parse", "--short", "HEAD"), runtimeDirty: git("status", "--porcelain", "--", "Resources/browser-repl") !== "", runtimeSha256: h.digest("hex").slice(0, 12), at: new Date().toISOString() };
}

function summarizeGt(gt) {
  const vis = gt.items.filter((x) => x.visible && !x.ariaHidden);
  return {
    interactiveVisible: vis.length,
    interactiveVisibleNamed: vis.filter((x) => x.name).length,
    interactiveInViewport: vis.filter((x) => x.inViewport).length,
    interactiveHidden: gt.items.filter((x) => !x.visible).length,
    inFrames: vis.filter((x) => x.frameDepth > 0).length,
    inShadow: { open: vis.filter((x) => x.shadow === "open").length, closed: vis.filter((x) => x.shadow === "closed").length },
    frames: gt.frames.length,
    hiddenTexts: gt.hiddenTexts.length,
  };
}

main().then(
  () => process.exit(0),
  (e) => {
    console.error(e.stack || e);
    process.exit(1);
  },
);
