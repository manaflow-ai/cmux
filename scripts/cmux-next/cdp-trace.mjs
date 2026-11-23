#!/usr/bin/env node
// A Chromium trace of a Debug cmux over its DevTools port (the app opens it with
// CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N), browser-wide (renderer, GPU and viz), with no
// Playwright: node's own WebSocket and fetch. Writes the trace JSON (chrome://tracing and Perfetto open it).
//
//   node scripts/cmux-next/cdp-trace.mjs PORT SECONDS OUT.json [CATEGORIES]
//
// The default categories are the ones that place a key's input event, its main-thread tasks, the frames
// and their presentation: input, the main thread's tasks and frames, cc, viz and gpu.
import fs from "node:fs";

const [port, seconds, out, categories] = process.argv.slice(2);
if (!port || !seconds || !out) {
  console.error("usage: cdp-trace.mjs PORT SECONDS OUT.json [CATEGORIES]");
  process.exit(2);
}
const included = (
  categories ??
  [
    "input",
    "benchmark",
    "toplevel",
    "blink",
    "cc",
    "viz",
    "gpu",
    "devtools.timeline",
    "disabled-by-default-devtools.timeline",
    "disabled-by-default-devtools.timeline.frame",
    "latencyInfo",
    "disabled-by-default-histogram_samples",
    "scheduler",
    "renderer.scheduler",
  ].join(",")
).split(",");
const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const socket = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = reject;
});
let id = 1;
const waiting = new Map();
const events = [];
let complete;
const completed = new Promise((resolve) => (complete = resolve));
socket.onmessage = (message) => {
  const data = JSON.parse(String(message.data));
  if (data.id) {
    waiting.get(data.id)?.(data);
    waiting.delete(data.id);
  } else if (data.method === "Tracing.dataCollected") {
    events.push(...data.params.value);
  } else if (data.method === "Tracing.tracingComplete") {
    complete();
  }
};
const send = (method, params = {}) =>
  new Promise((resolve) => {
    const n = id++;
    waiting.set(n, resolve);
    socket.send(JSON.stringify({ id: n, method, params }));
  });
const started = await send("Tracing.start", {
  transferMode: "ReportEvents",
  traceConfig: { recordMode: "recordContinuously", includedCategories: included },
});
if (started.error) {
  console.error(`Tracing.start: ${JSON.stringify(started.error)}`);
  process.exit(1);
}
console.log(`TRACE started (${included.length} categories)`);
// The trace's window: the measured keys run meanwhile (the bench starts this first).
await new Promise((resolve) => setTimeout(resolve, Number(seconds) * 1000));
await send("Tracing.end");
await completed;
socket.close();
fs.writeFileSync(out, JSON.stringify({ traceEvents: events }));
console.log(`TRACE ${events.length} events -> ${out}`);
