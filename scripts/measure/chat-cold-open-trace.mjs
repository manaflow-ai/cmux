#!/usr/bin/env node
// A cold chat open's V8 parse+compile and script bytes in cmux NEXT's own Chromium (CEF), whole browser traced.
//
//   node scripts/measure/chat-cold-open-trace.mjs --port PORT --out FILE [--settle MS] [--match SUBSTRING]
//
// Attaches to the browser target of a cmux started with CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=PORT,
// starts a trace of every process, prints `TRACING` on stdout once the trace runs, and waits for one line on stdin
// (the driver opens a chat, scripts/measure/chat-cold-open.py, then writes a line). It keeps tracing --settle ms
// after that line, then writes one JSON summary to --out and stdout.
//
// The chat is the renderer process that fetched a URL with --match (default `pane.js`, the agent pane's entry).
// In that process, every thread (the main thread and its workers):
// - parseCompileMs: wall time inside V8 parse and compile events (V8.ParseProgram, V8.ParseFunction,
//   V8.CompileCode, V8.CompileLazy, v8.compile, v8.compileModule, v8.parseOnBackground, v8.compileOnBackground,
//   V8.CompileDeserialize, v8.deserializeOnBackground). Nested events count once (interval union per thread).
//   A code cache hit shows as deserialize time in place of parse and compile.
// - mainParseCompileMs: the same on the main thread only.
// - scriptBytes: decoded bytes of every script the process fetched (ResourceFinish of a .js URL, its query aside);
//   scriptFiles: how many.
// - cacheConsumed / cacheProduced: code cache deserializations and writes.
import fs from "node:fs";

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
};
const port = arg("--port");
const out = arg("--out");
const settle = Number(arg("--settle", "8000"));
const match = arg("--match", "pane.js");
if (!port || !out) {
  console.error("usage: chat-cold-open-trace.mjs --port PORT --out FILE [--settle MS] [--match SUBSTRING]");
  process.exit(2);
}

const CATEGORIES = ["devtools.timeline", "v8", "v8.execute", "disabled-by-default-v8.compile", "loading", "__metadata"];
const PARSE_COMPILE = new Set([
  "V8.ParseProgram",
  "V8.ParseFunction",
  "V8.CompileCode",
  "V8.CompileLazy",
  "V8.CompileEval",
  "v8.compile",
  "v8.compileModule",
  "v8.parseOnBackground",
  "v8.compileOnBackground",
  "V8.CompileDeserialize",
  "v8.deserializeOnBackground",
]);
const CONSUMED = new Set(["V8.CompileDeserialize", "v8.deserializeOnBackground"]);
const PRODUCED = new Set(["v8.produceModuleCache", "v8.produceCache"]);

async function browserSocket() {
  for (let i = 0; i < 300; i++) {
    try {
      const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
      if (version.webSocketDebuggerUrl) return version.webSocketDebuggerUrl;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`no browser target on port ${port}`);
}

const ws = new WebSocket(await browserSocket());
await new Promise((resolve, reject) => {
  ws.onopen = resolve;
  ws.onerror = reject;
});
let id = 0;
const waiting = new Map();
const events = [];
let traceDone = () => {};
ws.onmessage = (m) => {
  const msg = JSON.parse(String(m.data));
  if (msg.id && waiting.has(msg.id)) {
    waiting.get(msg.id)(msg);
    waiting.delete(msg.id);
  } else if (msg.method === "Tracing.dataCollected") events.push(...msg.params.value);
  else if (msg.method === "Tracing.tracingComplete") traceDone();
};
const send = (method, params = {}) =>
  new Promise((resolve) => {
    const i = ++id;
    waiting.set(i, resolve);
    ws.send(JSON.stringify({ id: i, method, params }));
  });

const complete = new Promise((r) => (traceDone = r));
const started = await send("Tracing.start", { traceConfig: { includedCategories: CATEGORIES }, transferMode: "ReportEvents" });
if (started.error) {
  console.error(`Tracing.start: ${JSON.stringify(started.error)}`);
  process.exit(1);
}
console.log("TRACING");
await new Promise((resolve) => {
  process.stdin.once("data", resolve);
  process.stdin.once("end", resolve);
});
const openedAt = Date.now();
await new Promise((r) => setTimeout(r, settle));
await send("Tracing.end");
await complete;
ws.close();

// Request id -> URL (ResourceSendRequest), then the process that finished a request for the entry.
const urls = new Map();
for (const e of events) {
  if (e.name === "ResourceSendRequest" && e.args?.data?.requestId) urls.set(e.args.data.requestId, { url: e.args.data.url, pid: e.pid });
}
const isScript = (url) => /\.(m?js)$/.test(String(url).split(/[?#]/)[0]);
const chatPids = new Set([...urls.values()].filter((r) => String(r.url).includes(match)).map((r) => r.pid));
const threadNames = new Map(events.filter((e) => e.name === "thread_name").map((e) => [`${e.pid}:${e.tid}`, e.args?.name]));

function unionMs(list) {
  const spans = list.map((e) => [e.ts, e.ts + (e.dur || 0)]).sort((a, b) => a[0] - b[0]);
  let total = 0;
  let [start, end] = [null, null];
  for (const [s, f] of spans) {
    if (end === null || s > end) {
      if (end !== null) total += end - start;
      [start, end] = [s, f];
    } else end = Math.max(end, f);
  }
  if (end !== null) total += end - start;
  return total / 1000;
}

function forPid(pid) {
  const mine = events.filter((e) => e.pid === pid);
  const byThread = new Map();
  for (const e of mine) {
    if (e.ph !== "X" || !PARSE_COMPILE.has(e.name)) continue;
    const key = `${e.pid}:${e.tid}`;
    if (!byThread.has(key)) byThread.set(key, []);
    byThread.get(key).push(e);
  }
  const threads = {};
  let parseCompileMs = 0;
  let mainParseCompileMs = 0;
  for (const [key, list] of byThread) {
    const ms = unionMs(list);
    const name = threadNames.get(key) || key;
    threads[name] = Math.round(((threads[name] || 0) + ms) * 10) / 10;
    parseCompileMs += ms;
    if (name === "CrRendererMain") mainParseCompileMs += ms;
  }
  let scriptBytes = 0;
  let scriptFiles = 0;
  for (const e of mine) {
    if (e.name !== "ResourceFinish") continue;
    const req = urls.get(e.args?.data?.requestId);
    if (!req || !isScript(req.url)) continue;
    scriptFiles += 1;
    scriptBytes += Number(e.args.data.decodedBodyLength || e.args.data.encodedDataLength || 0);
  }
  return {
    pid,
    parseCompileMs: Math.round(parseCompileMs * 10) / 10,
    mainParseCompileMs: Math.round(mainParseCompileMs * 10) / 10,
    scriptBytes,
    scriptFiles,
    cacheConsumed: mine.filter((e) => CONSUMED.has(e.name)).length,
    cacheProduced: mine.filter((e) => PRODUCED.has(e.name)).length,
    threads,
  };
}

const chats = [...chatPids].map(forPid);
// The chat: the renderer that compiled the most (a spare page that fetched pane.js earlier compiles nothing here).
const chat = chats.sort((a, b) => b.parseCompileMs - a.parseCompileMs)[0] || null;
const summary = { openedAt, settleMs: settle, match, events: events.length, chat, others: chats.slice(1) };
fs.writeFileSync(out, JSON.stringify(summary, null, 1));
console.log(JSON.stringify(summary));
process.exit(chat ? 0 : 3);
