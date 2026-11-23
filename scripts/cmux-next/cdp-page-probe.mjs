#!/usr/bin/env node
// What the shown New Tab page spends on the host's places pushes while keys are typed, over its DevTools port,
// with no profiler (a profiler slows the page it measures): each `linkPlaces` (the whole list) and
// `linkPlacesChanged` (renamed places only) call the page's bridge gets, the places it carries and its time (the parse of the pushed script itself is
// before the call, so the long tasks count it and the call time does not), and the
// page's long tasks (over 50 ms).
//
//   node scripts/cmux-next/cdp-page-probe.mjs PORT SECONDS [SELECTOR=.nt-field]
//
// Prints one JSON line: calls and places per kind, their summed and longest ms, long tasks and their sum.
const [port, seconds, selector = ".nt-field"] = process.argv.slice(2);
if (!port || !seconds) {
  console.error("usage: cdp-page-probe.mjs PORT SECONDS [SELECTOR]");
  process.exit(2);
}
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const pages = targets.filter((target) => target.type === "page" && target.url.includes("cmux.agent"));
/// A DevTools session on `target`: its socket and `send(method, params)`, resolved with the reply.
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
const evaluate = async (send, expression) =>
  (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result?.result?.value;
// The shown page: the one whose document has SELECTOR and is visible.
let chosen;
for (const target of pages) {
  const session = await connect(target);
  const ok = await evaluate(
    session.send,
    `!!document.querySelector(${JSON.stringify(selector)}) && document.visibilityState === "visible"`,
  );
  if (ok && !chosen) chosen = session;
  else session.socket.close();
}
if (!chosen) {
  console.error(`no visible page shows ${selector}`);
  process.exit(1);
}
const install = `(() => {
  const bridge = window.cmuxAcpmuxBridge;
  const stats = { linkPlaces: { calls: 0, places: 0, ms: 0, max: 0 }, linkPlacesChanged: { calls: 0, places: 0, ms: 0, max: 0 },
                  longTasks: 0, longTaskMs: 0, bridge: !!bridge };
  window.__placesProbe = stats;
  const wrap = (name, kind) => {
    const original = bridge?.[name];
    if (typeof original !== "function") return;
    bridge[name] = function (value) {
      const start = performance.now();
      try { return original.call(this, value); } finally {
        const ms = performance.now() - start;
        const entry = stats[kind];
        entry.calls += 1; entry.ms += ms; entry.max = Math.max(entry.max, ms);
        entry.places += Array.isArray(value) ? value.length : 0;
      }
    };
  };
  wrap("applyLinkPlaces", "linkPlaces");
  wrap("applyLinkPlacesChanged", "linkPlacesChanged");
  // The page host's path (pageHost.ts): every host event comes through one receive hook as
  // {t: "ev", data: {kind, value}}.
  const receive = window.__cmuxPageReceive;
  stats.pageHost = typeof receive === "function";
  if (stats.pageHost) {
    window.__cmuxPageReceive = function (message) {
      const kind = message?.t === "ev" ? message.data?.kind : undefined;
      const entry = kind === "linkPlaces" || kind === "linkPlacesChanged" ? stats[kind] : undefined;
      const start = performance.now();
      try { return receive.call(this, message); } finally {
        if (entry) {
          const ms = performance.now() - start;
          entry.calls += 1; entry.ms += ms; entry.max = Math.max(entry.max, ms);
          entry.places += Array.isArray(message.data.value) ? message.data.value.length : 0;
        }
      }
    };
  }
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) { stats.longTasks += 1; stats.longTaskMs += entry.duration; }
    }).observe({ type: "longtask" });
  } catch {}
  return true;
})()`;
await evaluate(chosen.send, install);
await new Promise((resolve) => setTimeout(resolve, Number(seconds) * 1000));
const stats = await evaluate(chosen.send, "window.__placesProbe");
chosen.socket.close();
const round = (value) => Math.round(value * 10) / 10;
for (const kind of ["linkPlaces", "linkPlacesChanged"]) {
  stats[kind].ms = round(stats[kind].ms);
  stats[kind].max = round(stats[kind].max);
}
stats.longTaskMs = round(stats.longTaskMs);
stats.seconds = Number(seconds);
console.log(`PROBE ${JSON.stringify(stats)}`);
