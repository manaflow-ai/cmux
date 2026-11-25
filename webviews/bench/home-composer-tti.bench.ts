// l10n-allow-file: benchmark output, not shipped UI.
// How soon Home's Channels page takes a key in its composer on a cold open (startup-tti lane; Leo, 2026-11-19:
// "startup times and time to first interaction"). The page is served exactly as the app ships it: a
// `scripts/cmux-next/build-pages-web.sh --out DIR` tree (DIR/home-channels/index.html, DIR/__shared/*), with its
// modulepreload links, its per-locale string scripts when the page has them, and the production React build.
// `?mock` runs the real page against its in-page mock provider (no daemon), so the number is the page's own cost:
// fetch, parse and run its startup JS, draw the list and open the default conversation's composer.
//
// Each round is a fresh browser process (no HTTP or code cache, as a cold launch's renderer) and one page:
//   ready_ms   performance.now() when the composer's field is first in the document and editable
//              (`.lg-main-compose [contenteditable=true]`, read by a MutationObserver from the first byte);
//   key_ms     performance.now() of the first `input` event in that field after Playwright types one letter into it
//              as soon as it exists (so ready_ms plus the driver's round trip; the letter must land);
//   fcp_ms     first-contentful-paint;
//   js_bytes   decoded bytes of every script the page fetched before key_ms, and js_files their count;
//   script_ms  main-thread script time until key_ms (CDP Performance.getMetrics ScriptDuration).
// With --arms A=DIR,B=DIR it measures two builds in one run, interleaved A B B A per round, and prints each arm's
// median and [interquartile range].
//   bun bench/home-composer-tti.bench.ts --pages /tmp/pages [--rounds 12] [--cpu 4]
//   bun bench/home-composer-tti.bench.ts --arms base=/tmp/base,head=/tmp/head [--rounds 12] [--cpu 4]
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { chromium } from "./browsers";
import { requireProductionReact } from "./support/benchPage";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const ROUNDS = Number(flag("--rounds") ?? 12);
const CPU = Number(flag("--cpu") ?? 1);
const PAGE = flag("--page") ?? "home-channels";
const FIELD = ".lg-main-compose [contenteditable=true]";
const arms = (flag("--arms") ?? `pages=${flag("--pages") ?? ""}`).split(",").map((entry) => {
  const at = entry.indexOf("=");
  const dir = path.resolve(entry.slice(at + 1));
  if (!fs.existsSync(path.join(dir, PAGE, "index.html")))
    throw new Error(`${entry}: no ${PAGE}/index.html (pass a build-pages-web.sh --out directory)`);
  return { name: entry.slice(0, at), dir };
});

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
};

function serve(dir: string) {
  return Bun.serve({
    port: 0,
    fetch(request) {
      const rel = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "");
      const file = path.resolve(dir, rel);
      if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile())
        return new Response("not found", { status: 404 });
      return new Response(Bun.file(file), {
        headers: {
          "content-type": TYPES[path.extname(file)] ?? "application/octet-stream",
          "cache-control": "no-store",
        },
      });
    },
  });
}

// Runs before the page's first script: notes when the field first exists and is editable, and its first input.
const PROBE = `(() => {
  const marks = (window.__tti = {});
  const check = () => {
    if (marks.ready === undefined && document.querySelector(${JSON.stringify(FIELD)})) marks.ready = performance.now();
  };
  new MutationObserver(check).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ["contenteditable"] });
  document.addEventListener("input", (event) => {
    if (marks.key === undefined && event.target instanceof Element && event.target.closest(".lg-main-compose")) marks.key = performance.now();
  }, true);
})();`;

type Row = Record<string, number>;

async function measure(origin: string): Promise<Row> {
  const browser = await chromium.launch({ headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    await cdp.send("Performance.enable");
    if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
    await page.addInitScript(PROBE);
    await page.goto(`${origin}/${PAGE}/index.html?mock`, { waitUntil: "commit" });
    const field = await page.waitForSelector(FIELD, { timeout: 60_000 });
    await field.focus();
    await page.keyboard.type("x");
    await page.waitForFunction(() => (window as unknown as { __tti: { key?: number } }).__tti.key !== undefined, null, {
      timeout: 30_000,
    });
    const { metrics } = await cdp.send("Performance.getMetrics");
    const script = metrics.find((metric) => metric.name === "ScriptDuration")?.value ?? 0;
    const row = await page.evaluate(() => {
      const marks = (window as unknown as { __tti: { ready: number; key: number } }).__tti;
      const scripts = performance
        .getEntriesByType("resource")
        .filter((entry) => (entry as PerformanceResourceTiming).initiatorType !== "fetch")
        .filter(
          (entry) => /\.m?js(\?|$)/.test(entry.name) && entry.startTime <= marks.key,
        ) as PerformanceResourceTiming[];
      const fcp = performance.getEntriesByName("first-contentful-paint")[0]?.startTime ?? -1;
      return {
        ready_ms: marks.ready,
        key_ms: marks.key,
        fcp_ms: fcp,
        js_bytes: scripts.reduce((sum, entry) => sum + entry.decodedBodySize, 0),
        js_files: scripts.length,
      };
    });
    await requireProductionReact(page, { dev: false });
    return { ...row, script_ms: script * 1000 };
  } finally {
    await browser.close();
  }
}

const quantile = (values: number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (sorted.length - 1) * q;
  const low = Math.floor(at);
  return sorted[low]! + (sorted[Math.min(low + 1, sorted.length - 1)]! - sorted[low]!) * (at - low);
};

const servers = arms.map((arm) => ({ ...arm, server: serve(arm.dir) }));
const rows = new Map<string, Row[]>(arms.map((arm) => [arm.name, []]));
try {
  // One cold run per arm first, not counted: the OS file cache holds every arm's files alike.
  for (const arm of servers) await measure(`http://127.0.0.1:${arm.server.port}`);
  for (let round = 0; round < ROUNDS; round++) {
    const order = round % 2 === 0 ? servers : [...servers].reverse();
    for (const arm of order) {
      const row = await measure(`http://127.0.0.1:${arm.server.port}`);
      rows.get(arm.name)!.push(row);
      console.log(`RUN ${JSON.stringify({ arm: arm.name, round, ...row })}`);
    }
  }
} finally {
  await Promise.all(servers.map((arm) => arm.server.stop(true)));
}

const keys = ["ready_ms", "key_ms", "fcp_ms", "script_ms", "js_bytes", "js_files"];
console.log(`\nhome composer TTI: page=${PAGE} rounds=${ROUNDS} cpu=${CPU}x, fresh Chromium per run, median [q1-q3]`);
console.log(["arm", ...keys].join("\t"));
for (const [name, list] of rows) {
  const cells = keys.map((key) => {
    const values = list.map((row) => row[key]!);
    const fmt = (value: number) => (key === "js_bytes" ? Math.round(value).toLocaleString("en-US") : value.toFixed(0));
    return `${fmt(quantile(values, 0.5))} [${fmt(quantile(values, 0.25))}-${fmt(quantile(values, 0.75))}]`;
  });
  console.log([name, ...cells].join("\t"));
}
