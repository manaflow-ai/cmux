#!/usr/bin/env node
// One web-perf harness for every surface: TTFB, LCP, INP and JS kB per page.
//
//   node webviews/scripts/web-perf/vitals.mjs --runs 5 --out "$FAST_CHECKS_OUT/vitals.json" URL [URL...]
//   node webviews/scripts/web-perf/vitals.mjs --interact 'button,[role=tab]' URL
//
// Chromium (Playwright), a fresh context per run (cold cache), 4x CPU slowdown and a
// 10 Mbps / 40 ms network, so a laptop-class page reads like a mid-range phone. Reports the
// median of --runs. INP comes from scripted clicks on the first few --interact targets
// (default: buttons, links that stay on the page, tabs), measured by Event Timing the way
// web-vitals does: the slowest interaction's duration. JS kB is the wire size of every
// script response (and its decoded size), including code-split chunks loaded before idle.

import { chromium } from "playwright";
import { writeFileSync } from "node:fs";

const args = process.argv.slice(2);
let runs = 5;
let out = "";
let interact = "button:visible, [role=tab]:visible, summary:visible";
let throttle = true;
const urls = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--runs") runs = Number(args[++i]);
  else if (a === "--out") out = args[++i];
  else if (a === "--interact") interact = args[++i];
  else if (a === "--no-throttle") throttle = false;
  else urls.push(a);
}
if (urls.length === 0 || !Number.isInteger(runs) || runs < 1) {
  console.error("usage: vitals.mjs [--runs N>=1] [--out FILE] [--interact SELECTOR] [--no-throttle] URL...");
  process.exit(2);
}

const median = (xs) => {
  const s = xs.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (s.length === 0) return null;
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

const OBSERVE = `
  window.__vitals = { lcp: 0, inp: 0 };
  new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__vitals.lcp = e.startTime; })
    .observe({ type: "largest-contentful-paint", buffered: true });
  new PerformanceObserver((l) => {
    for (const e of l.getEntries()) if (e.interactionId) window.__vitals.inp = Math.max(window.__vitals.inp, e.duration);
  }).observe({ type: "event", buffered: true, durationThreshold: 16 });
`;

async function once(browser, url) {
  const context = await browser.newContext({ viewport: { width: 412, height: 915 }, deviceScaleFactor: 2 });
  await context.addInitScript(OBSERVE);
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  if (throttle) {
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await cdp.send("Network.enable");
    await cdp.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: 40,
      downloadThroughput: (10 * 1024 * 1024) / 8,
      uploadThroughput: (5 * 1024 * 1024) / 8,
    });
  }
  const js = { wire: 0, decoded: 0, files: 0 };
  // Every script's sizes are read before the context closes, so late chunks still count.
  const scriptReads = [];
  page.on("response", (r) => {
    if (r.request().resourceType() !== "script") return;
    scriptReads.push(
      (async () => {
        const sizes = await r.request().sizes();
        const body = await r.body();
        js.wire += sizes.responseBodySize || body.length;
        js.decoded += body.length;
        js.files += 1;
      })().catch(() => {}),
    );
  });
  const t0 = Date.now();
  await page.goto(url, { waitUntil: "load", timeout: 90_000 });
  await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => {});
  const ttfb = await page.evaluate(() => {
    const n = performance.getEntriesByType("navigation")[0];
    return n ? n.responseStart - n.requestStart : null;
  });
  // LCP is final at the first input, so read it before interacting, once it has held
  // still for a second (late images, fonts and paints arrive after network idle).
  let lcp = await page.evaluate(() => window.__vitals.lcp);
  for (let waited = 0; waited < 10_000; waited += 1_000) {
    await page.waitForTimeout(1_000);
    const next = await page.evaluate(() => window.__vitals.lcp);
    if (next === lcp) break;
    lcp = next;
  }
  const targets = await page.locator(interact).all();
  for (const el of targets.slice(0, 5)) {
    const href = await el.getAttribute("href").catch(() => null);
    if (href && !href.startsWith("#")) continue;
    await el.click({ timeout: 2_000, noWaitAfter: true }).catch(() => {});
    await page.waitForTimeout(300);
    if (page.url() !== url) break;
  }
  await page.waitForTimeout(500);
  const inp = await page.evaluate(() => window.__vitals.inp).catch(() => null);
  await Promise.all(scriptReads);
  await context.close();
  return {
    ttfb,
    lcp,
    inp,
    jsWireKB: js.wire / 1024,
    jsDecodedKB: js.decoded / 1024,
    jsFiles: js.files,
    wallMs: Date.now() - t0,
  };
}

// The fleet's arm64 machines have only chrome-headless-shell (CMUX_CHROME_HEADLESS_SHELL);
// x64 CI installs system Chrome (as scripts/latency/run.ts uses), not Playwright's bundled
// Chromium. Take whichever this machine has.
const headlessShell = process.env.CMUX_CHROME_HEADLESS_SHELL;
const browser = await (
  headlessShell
    ? chromium.launch({ headless: true, executablePath: headlessShell })
    : chromium.launch({ headless: true, channel: "chrome" })
).catch(() => chromium.launch({ headless: true }));
const results = [];
for (const url of urls) {
  const samples = [];
  for (let i = 0; i < runs; i++) {
    try {
      samples.push(await once(browser, url));
    } catch (e) {
      console.error(`${url} run ${i}: ${e.message}`);
    }
  }
  const pick = (k) => median(samples.map((s) => s[k]));
  const row = {
    url,
    runs: samples.length,
    ttfbMs: pick("ttfb"),
    lcpMs: pick("lcp"),
    inpMs: pick("inp"),
    jsWireKB: pick("jsWireKB"),
    jsDecodedKB: pick("jsDecodedKB"),
    jsFiles: pick("jsFiles"),
    samples,
  };
  results.push(row);
  const f = (x) => (x == null ? "-" : Math.round(x));
  console.log(
    `${url}\tTTFB ${f(row.ttfbMs)} ms\tLCP ${f(row.lcpMs)} ms\tINP ${f(row.inpMs)} ms\tJS ${f(row.jsWireKB)} kB wire / ${f(row.jsDecodedKB)} kB decoded (${f(row.jsFiles)} files)`,
  );
}
await browser.close();
const meta = {
  harness: "vitals.mjs",
  throttle: throttle ? "cpu4x,10mbps,40ms" : "none",
  viewport: "412x915@2",
  runs,
  at: new Date().toISOString(),
};
if (out) writeFileSync(out, JSON.stringify({ meta, results }, null, 2));
const empty = results.filter((r) => r.runs === 0).map((r) => r.url);
if (empty.length > 0) {
  console.error(`no sample collected for: ${empty.join(" ")}`);
  process.exit(1);
}
