#!/usr/bin/env node
// A CPU profile of one Chromium page of a Debug cmux over its DevTools port (the app opens it with
// CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=N, as scripts/cmux-next/trace.py does), with no
// Playwright: node's own WebSocket and fetch. Prints the functions by self time, ms, and writes the
// .cpuprofile (Chrome DevTools opens it).
//
//   node scripts/cmux-next/cdp-page-profile.mjs PORT SECONDS OUT.cpuprofile [URL_SUBSTRING]
//
// URL_SUBSTRING picks the pages (default `cmux.agent`); of those, the one where SELECTOR (default `.nt-field`, the
// New Tab field) is in the document is profiled.
import fs from "node:fs";
import path from "node:path";

const [port, seconds, out, match = "cmux.agent", selector = ".nt-field"] = process.argv.slice(2);
if (!port || !seconds || !out) {
  console.error("usage: cdp-page-profile.mjs PORT SECONDS OUT.cpuprofile [URL_SUBSTRING]");
  process.exit(2);
}
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const pages = targets.filter((target) => target.type === "page" && target.url.includes(match));
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
let chosen;
for (const target of pages) {
  const session = await connect(target);
  const reply = await session.send("Runtime.evaluate", {
    expression: `!!document.querySelector(${JSON.stringify(selector)})`,
    returnByValue: true,
  });
  if (reply.result?.result?.value === true && !chosen) chosen = { target, ...session };
  else session.socket.close();
}
if (!chosen) {
  console.error(`no page shows ${selector}: ${targets.map((t) => `${t.type} ${t.url}`).join(" | ")}`);
  process.exit(1);
}
const { target, socket, send } = chosen;
await send("Profiler.enable");
await send("Profiler.setSamplingInterval", { interval: 250 });
await send("Profiler.start");
// The profile's window: the measured keys run meanwhile (the bench starts this first).
await new Promise((resolve) => setTimeout(resolve, Number(seconds) * 1000));
const { result } = await send("Profiler.stop");
socket.close();
const profile = result.profile;
fs.writeFileSync(out, JSON.stringify(profile));
const nodes = new Map(profile.nodes.map((node) => [node.id, node]));
const self = new Map();
let total = 0;
profile.samples.forEach((id, index) => {
  const frame = nodes.get(id)?.callFrame;
  const ms = (profile.timeDeltas[index] ?? 0) / 1000;
  const name = frame ? `${frame.functionName || "(anonymous)"} ${path.basename(frame.url || "")}:${frame.lineNumber + 1}` : "?";
  if (!name.startsWith("(idle)")) total += ms;
  self.set(name, (self.get(name) ?? 0) + ms);
});
const top = [...self.entries()].filter(([name]) => !name.startsWith("(idle)")).sort((a, b) => b[1] - a[1]).slice(0, 25);
console.log(`PROFILE ${target.url.slice(0, 80)} busy ${total.toFixed(0)} ms of ${seconds} s`);
for (const [name, ms] of top) console.log(`  ${ms.toFixed(1).padStart(8)} ms  ${name}`);
