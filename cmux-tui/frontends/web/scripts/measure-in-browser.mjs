// Drive headless Chrome over CDP against a cmux page served by the daemon:
// first paint, time to a live terminal, keystroke-to-echo, screenshots.
// usage: node scripts/measure-in-browser.mjs URL OUTDIR [RUNS]  (needs google-chrome)
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [url, outDir, runsArg] = process.argv.slice(2);
const runs = Number(runsArg || 40);
if (!url || !outDir) {
  console.error("usage: measure-in-browser.mjs URL OUTDIR [RUNS]");
  process.exit(2);
}
mkdirSync(outDir, { recursive: true });
const port = 9300 + Math.floor(Math.random() * 500);
// The profile's history holds the URL with its token: it is removed on exit.
const profile = mkdtempSync(join(tmpdir(), "webproto-chrome-"));
process.on("exit", () => rmSync(profile, { recursive: true, force: true }));
const chrome = spawn(
  "google-chrome",
  [
    "--headless=new",
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    "--window-size=1440,900",
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank",
  ],
  { stdio: "ignore" },
);
chrome.on("error", (error) => {
  console.error(`measure-in-browser: cannot start google-chrome: ${error.message}`);
  process.exit(2);
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let version;
for (let i = 0; i < 100 && !version; i++) {
  try {
    version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  } catch {
    await sleep(100);
  }
}
if (!version) {
  console.error("measure-in-browser: google-chrome did not open its debugging port");
  process.exit(1);
}
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let nextId = 1;
const pending = new Map();
const listeners = [];
ws.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
    return;
  }
  for (const l of listeners) l(msg);
});
const send = (method, params = {}, sessionId) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
    ws.send(JSON.stringify({ id, method, params, sessionId }));
  });
const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
const s = (m, p) => send(m, p, sessionId);
const evaluate = async (expression) =>
  (await s("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;
await s("Page.enable");
await s("Runtime.enable");
await s("Network.enable");
await s("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 2, mobile: false });

const frames = [];
listeners.push((m) => {
  if (m.method === "Network.webSocketFrameSent")
    frames.push({ dir: "sent", t: m.params.timestamp, data: m.params.response.payloadData });
  if (m.method === "Network.webSocketFrameReceived")
    frames.push({ dir: "recv", t: m.params.timestamp, data: m.params.response.payloadData });
});

const t0 = performance.now();
await s("Page.navigate", { url });
let ready;
for (let i = 0; i < 300; i++) {
  ready = await evaluate(`(() => {
    const grid = document.querySelector('.render-grid');
    const text = grid?.innerText ?? '';
    return { fcp: performance.getEntriesByName('first-contentful-paint')[0]?.startTime ?? null,
      dcl: performance.getEntriesByType('navigation')[0]?.domContentLoadedEventEnd ?? null,
      connected: !!document.querySelector('.connect-shell') ? null : performance.now(),
      clickedAt: window.__clickedAt ?? null,
      terminal: /\\$|#|%/.test(text) ? performance.now() : null };
  })()`);
  if (ready?.terminal) break;
  // An empty headless session: make its first workspace from the page, as a person would.
  if (!ready?.clickedAt) {
    await evaluate(`(() => {
      if (!/No workspaces/.test(document.body.innerText)) return;
      const button = [...document.querySelectorAll('button')].find((b) => /new workspace/.test(b.textContent));
      if (button) { window.__clickedAt = performance.now(); button.click(); }
    })()`);
  }
  await sleep(50);
}
const firstLoad = { ...ready, wallToLiveTerminalMs: performance.now() - t0 };
console.log("first load", firstLoad);
await s("Page.captureScreenshot", { format: "png" }).then((r) =>
  writeFileSync(join(outDir, "01-connected.png"), Buffer.from(r.data, "base64")),
);

// Focus the terminal input, then measure keydown -> grid text update -> next frame.
await evaluate(`(() => {
  const input = document.querySelector('.render-input') || document.querySelector('.render-terminal-host');
  input?.focus();
  window.__echo = [];
  window.__mark = null;
  window.addEventListener('keydown', () => { window.__mark = performance.now(); }, true);
  new MutationObserver(() => {
    if (window.__mark == null) return;
    const start = window.__mark; window.__mark = null;
    const dom = performance.now();
    requestAnimationFrame(() => setTimeout(() => window.__echo.push({ dom: dom - start, paint: performance.now() - start }), 0));
  }).observe(document.querySelector('.render-grid'), { subtree: true, childList: true, characterData: true });
  return !!input;
})()`);
const typeKey = async (ch) => {
  await s("Input.dispatchKeyEvent", { type: "keyDown", text: ch, key: ch, unmodifiedText: ch });
  await s("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
};
const framesBefore = frames.length;
for (let i = 0; i < runs; i++) {
  await typeKey("x");
  await sleep(120);
  await s("Input.dispatchKeyEvent", {
    type: "rawKeyDown",
    key: "Backspace",
    code: "Backspace",
    windowsVirtualKeyCode: 8,
  });
  await s("Input.dispatchKeyEvent", { type: "keyUp", key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 });
  await sleep(120);
}
const echo = await evaluate("window.__echo");
// Wire: each input frame sent -> the next frame received.
const wire = [];
const typed = frames.slice(framesBefore);
for (let i = 0; i < typed.length; i++) {
  if (typed[i].dir !== "sent") continue;
  const reply = typed.slice(i + 1).find((f) => f.dir === "recv");
  if (reply) wire.push((reply.t - typed[i].t) * 1000);
}
for (const ch of "echo hello from cmux in a browser") await typeKey(ch);
await s("Input.dispatchKeyEvent", {
  type: "rawKeyDown",
  key: "Enter",
  code: "Enter",
  windowsVirtualKeyCode: 13,
  text: "\r",
});
await s("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13 });
await sleep(800);
await s("Page.captureScreenshot", { format: "png" }).then((r) =>
  writeFileSync(join(outDir, "02-typed.png"), Buffer.from(r.data, "base64")),
);
const gridText = await evaluate("document.querySelector('.render-grid')?.innerText ?? ''");

const stats = (xs) => {
  const v = [...xs].sort((a, b) => a - b);
  if (v.length === 0) return { n: 0 };
  const q = (p) => v[Math.min(v.length - 1, Math.floor(p * v.length))];
  return {
    n: v.length,
    p50: +q(0.5).toFixed(2),
    p90: +q(0.9).toFixed(2),
    p99: +q(0.99).toFixed(2),
    max: +v[v.length - 1].toFixed(2),
  };
};
const result = {
  url: url.replace(/#token=.*/, "#token=<redacted>"),
  firstLoad,
  keyToDom: stats(echo.map((e) => e.dom)),
  keyToPaint: stats(echo.map((e) => e.paint)),
  wireSentToRecv: stats(wire),
  echoedLine: gridText.includes("hello from cmux in a browser"),
};
console.log(JSON.stringify(result, null, 2));
writeFileSync(join(outDir, "result.json"), JSON.stringify(result, null, 2));
ws.close();
chrome.kill();
process.exit(0);
