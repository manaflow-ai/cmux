// The gallery's open-and-idle cost in Chrome: how long a URL takes to show its first frame and be
// ready, the main-thread long tasks after that, the CPU it burns while nobody touches it, its
// memory, and the layout shift after first paint. Leo, 2026-11-04: "it doesn't lag the f***
// out of my computer/browser when I open it". Each scenario is one URL of a built gallery
// (`bun run gallery:build`); app-perf-budgets.json lists them and their budgets.
//
//   bun app-perf.ts --gallery-dir ../../webviews/dist/gallery --out /tmp/perf [--cpu 4] [--only id,id]
//
// It writes results.json and table.md (a Markdown table for a PR body) and prints a GitHub
// `::warning::` for each budget a scenario exceeds. It exits 0 unless --strict. It is a lane-run
// budget, not a CI gate (CLAUDE.md: no new CI gates or budgets): run it yourself before and after a
// change, on the fleet (`cmux-ci test ...`, see ENTRIES.md), never on a laptop.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { chromium, type Browser, type Page } from "playwright";

type Budget = { firstFrameMs?: number; readyMs?: number; longTaskMaxMs?: number; idleCpuPct?: number; cls?: number; heapMb?: number };
type Scenario = { id: string; title: string; url: string; budget: Budget };
type Config = { cpuThrottle: number; idleWindowMs: number; settleMs: number; scenarios: Scenario[] };

export type Result = {
  id: string;
  title: string;
  url: string;
  cpuThrottle: number;
  firstFrameMs: number | null;
  readyMs: number | null;
  ready: boolean;
  frames: number;
  longTasksAfterReady: number;
  longTaskMaxMs: number;
  idleCpuPct: number;
  idleRafPerSec: number;
  idleTimersPerSec: number;
  heapMb: number;
  domNodes: number;
  cls: number;
  overBudget: string[];
  /** Where the idle window's rAF and timer calls came from (the top sites, with counts). */
  idleSites: [string, number][];
};

function arg(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`);
  return index > 0 ? process.argv[index + 1] : undefined;
}

// Installed in every frame before its scripts: long tasks, layout shifts and the idle loop counters
// (requestAnimationFrame callbacks and timer firings) on one shared clock (epoch ms).
const PROBE = () => {
  type Probe = {
    longTasks: [number, number][];
    shifts: [number, number][];
    raf: number;
    timers: number;
    /** While set (the idle window), where each rAF and timer was scheduled from, counted. */
    diag: boolean;
    sites: Record<string, number>;
  };
  const probe: Probe = { longTasks: [], shifts: [], raf: 0, timers: 0, diag: false, sites: {} };
  const site = (kind: string) => {
    if (!probe.diag) return;
    const line = (new Error().stack ?? "").split("\n").slice(3, 5).map((frame) => frame.trim().replace(/\?[^:)]*/, "")).join(" < ");
    const key = `${kind} ${line}`;
    probe.sites[key] = (probe.sites[key] ?? 0) + 1;
  };
  (window as unknown as { __cmuxPerf: Probe }).__cmuxPerf = probe;
  const origin = performance.timeOrigin;
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) probe.longTasks.push([origin + entry.startTime, entry.duration]);
    }).observe({ type: "longtask", buffered: true });
  } catch {}
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as (PerformanceEntry & { value: number; hadRecentInput: boolean })[])
        if (!entry.hadRecentInput) probe.shifts.push([origin + entry.startTime, entry.value]);
    }).observe({ type: "layout-shift", buffered: true });
  } catch {}
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (callback) => (site("raf"), raf((time) => ((probe.raf += 1), callback(time))));
  for (const name of ["setTimeout", "setInterval"] as const) {
    const original = window[name].bind(window) as (handler: unknown, ms?: number, ...rest: unknown[]) => number;
    (window as unknown as Record<string, unknown>)[name] = (handler: unknown, ms?: number, ...rest: unknown[]) => (
      site(name),
      original(
        typeof handler === "function" ? (...a: unknown[]) => ((probe.timers += 1), (handler as (...b: unknown[]) => void)(...a)) : handler,
        ms,
        ...rest,
      ));
  }
};

type FrameProbe = {
  url: string;
  longTasks: [number, number][];
  shifts: [number, number][];
  raf: number;
  timers: number;
  sites: Record<string, number>;
  ready: boolean;
  fcp: number | null;
};

async function readProbes(page: Page): Promise<FrameProbe[]> {
  const out: FrameProbe[] = [];
  for (const frame of page.frames()) {
    // A lazy iframe that has not loaded yet is not part of what the page shows.
    if (frame.url() === "about:blank" || frame.url() === "") continue;
    try {
      out.push(
        await frame.evaluate(() => {
          const probe = (window as unknown as { __cmuxPerf?: FrameProbe }).__cmuxPerf;
          const fcp = performance.getEntriesByName("first-contentful-paint")[0];
          const root = document.documentElement;
          return {
            url: location.pathname + location.search.slice(0, 80),
            sites: probe?.sites ?? {},
            longTasks: probe?.longTasks ?? [],
            shifts: probe?.shifts ?? [],
            raf: probe?.raf ?? 0,
            timers: probe?.timers ?? 0,
            // A gallery stage, the shell or the mock app says it is ready; a plain page is ready at load.
            // A stage says it is ready (data-gallery-ready, or error); the shell and the mock app are
            // ready once they drew their views (their stages are counted on their own).
            ready:
              root.dataset.galleryReady === "1" ||
              root.dataset.galleryReady === "error" ||
              root.dataset.mockAppReady === "1" ||
              (document.getElementById("gallery") !== null && document.querySelector(".gallery-entry, .gallery-browse") !== null),
            fcp: fcp ? performance.timeOrigin + fcp.startTime : null,
          };
        }),
      );
    } catch {
      // A frame that navigated away mid-read.
    }
  }
  return out;
}

const sum = (values: number[]) => values.reduce((total, value) => total + value, 0);
const round = (value: number, places = 1) => Math.round(value * 10 ** places) / 10 ** places;

async function measure(browser: Browser, baseUrl: string, scenario: Scenario, config: Config): Promise<Result> {
  const context = await browser.newContext({ viewport: { width: 1512, height: 982 }, deviceScaleFactor: 1 });
  await context.addInitScript(PROBE);
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("Performance.enable");
  if (config.cpuThrottle > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: config.cpuThrottle });
  const navigationStart = Date.now();
  await page.goto(`${baseUrl}/${scenario.url}`, { waitUntil: "load", timeout: 60_000 });
  // Ready: every frame on screen reports ready (the shell's stages each load their own entry).
  let readyAt: number | null = null;
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    const probes = await readProbes(page);
    if (probes.length > 0 && probes.every((probe) => probe.ready)) {
      readyAt = Date.now();
      break;
    }
    await page.waitForTimeout(50);
  }
  const probesAtReady = await readProbes(page);
  const fcps = probesAtReady.map((probe) => probe.fcp).filter((value): value is number => value !== null);
  const firstFrame = fcps.length ? Math.min(...fcps) : null;
  await page.waitForTimeout(config.settleMs);
  // The idle window: nobody touches the page.
  for (const frame of page.frames())
    await frame.evaluate(() => {
      const probe = (window as unknown as { __cmuxPerf?: { diag: boolean } }).__cmuxPerf;
      if (probe) probe.diag = true;
    }).catch(() => {});
  const before = await readProbes(page);
  const metricsBefore = await cdp.send("Performance.getMetrics");
  const idleStart = Date.now();
  await page.waitForTimeout(config.idleWindowMs);
  const metricsAfter = await cdp.send("Performance.getMetrics");
  const idleMs = Date.now() - idleStart;
  const after = await readProbes(page);
  const metric = (set: typeof metricsBefore, name: string) => set.metrics.find((entry) => entry.name === name)?.value ?? 0;
  const taskSeconds = metric(metricsAfter, "TaskDuration") - metric(metricsBefore, "TaskDuration");
  const longTasks = after.flatMap((probe) => probe.longTasks).filter(([start]) => readyAt !== null && start >= readyAt);
  const shiftsAfterPaint = after.flatMap((probe) => probe.shifts).filter(([start]) => firstFrame !== null && start > firstFrame);
  const dom = await cdp.send("Memory.getDOMCounters").catch(() => ({ nodes: 0 }));
  await context.close();
  const result: Result = {
    id: scenario.id,
    title: scenario.title,
    url: scenario.url,
    cpuThrottle: config.cpuThrottle,
    firstFrameMs: firstFrame === null ? null : Math.round(Math.max(0, firstFrame - navigationStart)),
    readyMs: readyAt === null ? null : readyAt - navigationStart,
    ready: readyAt !== null,
    frames: after.length,
    longTasksAfterReady: longTasks.length,
    longTaskMaxMs: round(Math.max(0, ...longTasks.map(([, duration]) => duration))),
    idleCpuPct: round((taskSeconds * 1000 * 100) / idleMs),
    idleRafPerSec: round(((sum(after.map((p) => p.raf)) - sum(before.map((p) => p.raf))) * 1000) / idleMs),
    idleTimersPerSec: round(((sum(after.map((p) => p.timers)) - sum(before.map((p) => p.timers))) * 1000) / idleMs),
    heapMb: round(metric(metricsAfter, "JSHeapUsedSize") / 1048576),
    domNodes: (dom as { nodes: number }).nodes,
    cls: round(sum(shiftsAfterPaint.map(([, value]) => value)), 4),
    overBudget: [],
    idleSites: Object.entries(
      after.reduce<Record<string, number>>((all, probe) => {
        for (const [key, count] of Object.entries(probe.sites)) all[`${probe.url.split("?")[0]} ${key}`] = (all[`${probe.url.split("?")[0]} ${key}`] ?? 0) + count;
        return all;
      }, {}),
    )
      .sort((a, b) => b[1] - a[1])
      .slice(0, 12),
  };
  result.overBudget = overBudget(result, scenario.budget);
  return result;
}

export function overBudget(result: Result, budget: Budget): string[] {
  const over: string[] = [];
  const check = (name: keyof Budget, value: number | null) => {
    const limit = budget[name];
    if (limit !== undefined && (value === null || value > limit)) over.push(`${name} ${value ?? "never"} > ${limit}`);
  };
  check("firstFrameMs", result.firstFrameMs);
  check("readyMs", result.readyMs);
  check("longTaskMaxMs", result.longTaskMaxMs);
  check("idleCpuPct", result.idleCpuPct);
  check("cls", result.cls);
  check("heapMb", result.heapMb);
  return over;
}

export function table(results: Result[]): string {
  const ms = (value: number | null) => (value === null ? "never" : `${value} ms`);
  const lines = [
    `| Scenario | First frame | Ready | Long tasks after ready (max) | Idle CPU | Idle rAF/s | Idle timers/s | JS heap | DOM nodes | CLS after paint | Budget |`,
    `|---|---|---|---|---|---|---|---|---|---|---|`,
  ];
  for (const r of results)
    lines.push(
      `| ${r.title} (cpu ${r.cpuThrottle}x) | ${ms(r.firstFrameMs)} | ${ms(r.readyMs)} | ${r.longTasksAfterReady} (${r.longTaskMaxMs} ms) | ${r.idleCpuPct}% | ${r.idleRafPerSec} | ${r.idleTimersPerSec} | ${r.heapMb} MB | ${r.domNodes} | ${r.cls} | ${r.overBudget.length ? r.overBudget.join("; ") : "ok"} |`,
    );
  return lines.join("\n");
}

async function serve(root: string): Promise<{ baseUrl: string; close: () => void }> {
  const types: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".wasm": "application/wasm", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf" };
  const server = Bun.serve({
    port: 0,
    // Loopback only: the built gallery is never reachable from the network while a run lasts.
    hostname: "127.0.0.1",
    async fetch(request) {
      let requested: string;
      try {
        requested = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "") || "index.html";
      } catch {
        return new Response("bad request", { status: 400 });
      }
      const file = resolve(root, requested);
      if (file !== resolve(root) && !file.startsWith(resolve(root) + sep)) return new Response("forbidden", { status: 403 });
      try {
        return new Response(await readFile(file), { headers: { "content-type": types[extname(file)] ?? "application/octet-stream" } });
      } catch {
        return new Response("not found", { status: 404 });
      }
    },
  });
  return { baseUrl: `http://127.0.0.1:${server.port}`, close: () => server.stop() };
}

if (import.meta.main) {
  const galleryDir = resolve(arg("gallery-dir") ?? "../../webviews/dist/gallery");
  const out = resolve(arg("out") ?? "app-perf-out");
  const config = JSON.parse(await readFile(new URL("./app-perf-budgets.json", import.meta.url), "utf8")) as Config;
  if (arg("cpu")) config.cpuThrottle = Number(arg("cpu"));
  const only = arg("only")?.split(",");
  const scenarios = config.scenarios.filter((scenario) => !only || only.includes(scenario.id));
  await mkdir(out, { recursive: true });
  const server = await serve(galleryDir);
  const executablePath = process.env.CMUX_CHROME_HEADLESS_SHELL;
  const browser = await chromium.launch({ headless: true, ...(executablePath ? { executablePath } : { channel: "chrome" }) });
  const results: Result[] = [];
  try {
    for (const scenario of scenarios) {
      const result = await measure(browser, server.baseUrl, scenario, config);
      results.push(result);
      console.log(JSON.stringify(result));
      for (const over of result.overBudget) console.log(`::warning title=gallery perf budget::${scenario.id}: ${over}`);
    }
  } finally {
    await browser.close();
    server.close();
  }
  await writeFile(`${out}/results.json`, `${JSON.stringify(results, null, 2)}\n`);
  await writeFile(`${out}/table.md`, `${table(results)}\n`);
  console.log(table(results));
  if (process.argv.includes("--strict") && results.some((result) => result.overBudget.length)) process.exit(1);
}
