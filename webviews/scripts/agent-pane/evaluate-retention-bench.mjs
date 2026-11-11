// l10n-allow-file: bench output, not shipped UI.
// Does a page keep what the native host pushes through DevTools `Runtime.evaluate`? The agent pane's
// host sends every daemon frame as `window.cmuxAcpmuxTransport?.receive({...frames})`, one evaluate
// per batch, on a session with Page and Runtime enabled (ChromiumPageHostBridge). This pushes the
// same shape into a blank page that drops each frame, and reads the JS heap after a GC each interval:
// flat means the page and V8 let the pushes go; a climb is retention by the push path itself.
//
//   node scripts/agent-pane/evaluate-retention-bench.mjs [--seconds 180] [--rate 6] [--kb 20]
//     [--modes evaluate,binding-free,callFunctionOn]
import { chromium } from "playwright";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const SECONDS = Number(arg("seconds", "180"));
const RATE = Number(arg("rate", "6"));
const KB = Number(arg("kb", "20"));
const SAMPLE = Number(arg("sample", "30"));
const modes = arg("modes", "evaluate,evaluate-unique,callFunctionOn").split(",");

const browser = await chromium.launch();
const results = [];
for (const mode of modes) {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("about:blank");
  const cdp = await context.newCDPSession(page);
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Performance.enable");
  await cdp.send("HeapProfiler.enable");
  await page.evaluate(() => {
    globalThis.received = 0;
    globalThis.cmuxAcpmuxTransport = {
      receive: (event) => {
        globalThis.received += event.frames.length;
      },
    };
  });
  const heap = async () => {
    await cdp.send("HeapProfiler.collectGarbage");
    const m = Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((x) => [x.name, x.value]));
    return Math.round(m.JSHeapUsedSize / 1e5) / 10;
  };
  const { result: globalObject } = await cdp.send("Runtime.evaluate", { expression: "globalThis" });
  const pad = "x".repeat(KB * 1024);
  const start = await heap();
  const series = [];
  let n = 0;
  const t0 = Date.now();
  let nextSample = SAMPLE;
  while ((Date.now() - t0) / 1000 < SECONDS) {
    n += 1;
    // A frame like the daemon's: a JSON-RPC notification with a unique seq and a body of KB kilobytes.
    const frame = JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { seq: n, text: pad } });
    const event = { connection: 1, frames: [frame] };
    if (mode === "evaluate")
      await cdp.send("Runtime.evaluate", {
        expression: `window.cmuxAcpmuxTransport?.receive(${JSON.stringify(event)});`,
        silent: true,
      });
    else if (mode === "evaluate-unique")
      // The same, with each source also unique past the literal (as a batch of try blocks is).
      await cdp.send("Runtime.evaluate", {
        expression: `try {\nwindow.cmuxAcpmuxTransport?.receive(${JSON.stringify(event)});\n} catch (e) { console.error(e) }\n// ${n}`,
        silent: true,
      });
    else if (mode === "callFunctionOn")
      // One fixed function and the event as an argument: no new source per push.
      await cdp.send("Runtime.callFunctionOn", {
        objectId: globalObject.objectId,
        functionDeclaration: "function (event) { this.cmuxAcpmuxTransport?.receive(event); }",
        arguments: [{ value: event }],
        silent: true,
      });
    await new Promise((resolve) => setTimeout(resolve, 1000 / RATE));
    if ((Date.now() - t0) / 1000 >= nextSample) {
      series.push({ t: nextSample, heapMB: await heap() });
      nextSample += SAMPLE;
    }
  }
  const end = await heap();
  const received = await page.evaluate(() => globalThis.received);
  const pushedMB = Math.round((n * KB) / 102.4) / 10;
  const result = {
    mode,
    pushes: n,
    received,
    pushedMB,
    startMB: start,
    endMB: end,
    keptMB: Math.round((end - start) * 10) / 10,
    series,
  };
  results.push(result);
  console.log(JSON.stringify(result));
  await context.close();
}
await browser.close();
console.log("SUMMARY");
for (const r of results)
  console.log(
    `${r.mode}: ${r.pushes} pushes (${r.pushedMB} MB pushed), heap ${r.startMB} -> ${r.endMB} MB after GC (kept ${r.keptMB} MB); ${r.series.map((s) => `${s.t}s ${s.heapMB}`).join(" | ")}`,
  );
