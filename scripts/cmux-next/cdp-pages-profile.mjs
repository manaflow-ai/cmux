#!/usr/bin/env node
// A JS CPU profile of EVERY matching Chromium page of a Debug cmux at once, over its DevTools port (the app opens it
// with CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N:remote-allow-origins=*), for a renderer whose main thread
// is busy while no single page is known to be the cause (cmuxterm-hq#16576). cdp-page-profile.mjs profiles the one
// page that shows a selector; this one starts the profiler on all pages in the same instant, stops them together,
// and ranks the self time of functions across all pages and per page. Node 22+ (global fetch and WebSocket).
//
//   node scripts/cmux-next/cdp-pages-profile.mjs PORT SECONDS OUTDIR [URL_SUBSTRING] [MAX_PAGES]
//
// OUTDIR gets one `page-N.cpuprofile` per page (Chrome DevTools opens them) and `summary.json`. Stdout:
//   PAGES-PROFILE-PAGE n url visibility busy_ms
//   PAGES-PROFILE-TOP  self_ms  function  file:line   (all pages together, idle and program excluded)
//   PAGES-PROFILE-SUMMARY {json}
// The profile is the pages' JS only: native renderer work (layout, paint, style, GC outside script) shows as
// `(program)` and `(garbage collector)`, which summary.json keeps apart.
import fs from "node:fs";
import path from "node:path";

const [port, seconds, outDir, match = "cmux.agent", maxPages = "80"] = process.argv.slice(2);
if (!port || !seconds || !outDir) {
  console.error("usage: cdp-pages-profile.mjs PORT SECONDS OUTDIR [URL_SUBSTRING] [MAX_PAGES]");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const pages = targets.filter((target) => target.type === "page" && target.url.includes(match)).slice(0, Number(maxPages));
console.log(`PAGES-PROFILE-TARGETS ${targets.length} targets, ${pages.length} pages match ${match}`);

/// Opens a DevTools session on `target`: its socket and a `send(method, params)` that resolves with the reply.
async function connect(target) {
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  let id = 1;
  const waiting = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(String(event.data));
    waiting.get(message.id)?.(message);
    waiting.delete(message.id);
  };
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const n = id++;
      waiting.set(n, resolve);
      socket.send(JSON.stringify({ id: n, method, params }));
    });
  return { socket, send };
}

const sessions = [];
for (const target of pages) {
  try {
    const session = await connect(target);
    const state = await session.send("Runtime.evaluate", {
      expression: `JSON.stringify({visibility: document.visibilityState, title: document.title.slice(0, 40), nt: !!document.querySelector(".nt-field")})`,
      returnByValue: true,
    });
    const info = JSON.parse(state.result?.result?.value ?? "{}");
    sessions.push({ target, ...session, info });
  } catch (error) {
    console.log(`PAGES-PROFILE-SKIP ${target.url.slice(0, 80)} ${error}`);
  }
}
// One instant for every page: enable, then start, with no awaits between the starts.
await Promise.all(sessions.map(async (s) => {
  await s.send("Profiler.enable");
  await s.send("Profiler.setSamplingInterval", { interval: 1000 });
}));
const startedAt = Date.now();
await Promise.all(sessions.map((s) => s.send("Profiler.start")));
await new Promise((resolve) => setTimeout(resolve, Number(seconds) * 1000));
const stops = await Promise.all(sessions.map((s) => s.send("Profiler.stop")));
const windowMs = Date.now() - startedAt;

const overall = new Map();
const kinds = { idle: 0, program: 0, gc: 0, script: 0 };
const perPage = [];
sessions.forEach((s, index) => {
  s.socket.close();
  const profile = stops[index].result?.profile;
  if (!profile) return;
  fs.writeFileSync(path.join(outDir, `page-${index}.cpuprofile`), JSON.stringify(profile));
  const nodes = new Map(profile.nodes.map((node) => [node.id, node]));
  let busy = 0;
  const own = new Map();
  profile.samples.forEach((id, i) => {
    const frame = nodes.get(id)?.callFrame;
    const ms = (profile.timeDeltas[i] ?? 0) / 1000;
    const fn = frame?.functionName ?? "";
    if (fn === "(idle)") { kinds.idle += ms; return; }
    if (fn === "(program)") { kinds.program += ms; busy += ms; return; }
    if (fn === "(garbage collector)") { kinds.gc += ms; busy += ms; return; }
    kinds.script += ms;
    busy += ms;
    const name = `${fn || "(anonymous)"} ${path.basename(frame?.url || "")}:${(frame?.lineNumber ?? -1) + 1}`;
    overall.set(name, (overall.get(name) ?? 0) + ms);
    own.set(name, (own.get(name) ?? 0) + ms);
  });
  const topOwn = [...own.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([name, ms]) => ({ name, ms: Math.round(ms) }));
  perPage.push({ index, url: s.target.url.slice(0, 120), visibility: s.info.visibility, title: s.info.title, newTab: s.info.nt, busy_ms: Math.round(busy), top: topOwn });
  console.log(`PAGES-PROFILE-PAGE ${index} ${s.target.url.slice(0, 70)} ${s.info.visibility ?? "?"} busy ${busy.toFixed(0)} ms`);
});
const top = [...overall.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40);
for (const [name, ms] of top) console.log(`PAGES-PROFILE-TOP ${ms.toFixed(1).padStart(9)} ms  ${name}`);
const summary = {
  port: Number(port),
  window_ms: windowMs,
  pages: sessions.length,
  kinds_ms: Object.fromEntries(Object.entries(kinds).map(([k, v]) => [k, Math.round(v)])),
  top_self: top.map(([name, ms]) => ({ name, ms: Math.round(ms) })),
  per_page: perPage.sort((a, b) => b.busy_ms - a.busy_ms),
};
fs.writeFileSync(path.join(outDir, "summary.json"), JSON.stringify(summary, null, 1));
console.log(`PAGES-PROFILE-SUMMARY ${JSON.stringify({ window_ms: summary.window_ms, pages: summary.pages, kinds_ms: summary.kinds_ms, top_self: summary.top_self.slice(0, 15), busiest_pages: summary.per_page.slice(0, 5) })}`);
