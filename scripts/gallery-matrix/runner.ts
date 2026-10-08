#!/usr/bin/env bun
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, writeFile, rm } from "node:fs/promises";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, join, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { spawnSync } from "node:child_process";

export type Scalar = string | number | boolean;
export type MatrixCase = {
  id: string;
  path_or_url: string;
  params?: Record<string, Scalar>;
};
export type Engine = "chromium" | "webkit";
export type DiffResult = { differentPixels: number; totalPixels: number; percentage: number; passed: boolean };
export type Ledger = { runId: string; createdAt: string; vmIds: string[]; pausedVmIds?: string[]; deletedVmIds: string[] };

/** The action-to-settled summary shown on each ordinary matrix card. */
export function settleSummary(samples: readonly unknown[]) {
  const values = samples.filter((value): value is number => typeof value === "number" && Number.isFinite(value) && value >= 0).sort((a, b) => a - b);
  if (!values.length) return { count: 0, p50: 0, p95: 0, max: 0 };
  const at = (quantile: number) => values[Math.min(values.length - 1, Math.floor(quantile * values.length))]!;
  const round = (value: number) => Math.round(value * 10) / 10;
  return { count: values.length, p50: round(at(0.5)), p95: round(at(0.95)), max: round(values[values.length - 1]!) };
}

const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 800;
const DEFAULT_DEVICE_SCALE = 2;
/** A VM pauses itself after this much network idleness (at most 300 s, coordinator rule
 * 2026-10-07); the run's own pause by exact id is the primary path. */
const FREESTYLE_IDLE_SECONDS = 300;
/** Browsers run only inside a Freestyle VM (or CI), never on a developer laptop. */
const IN_VM = process.env.CMUX_GALLERY_IN_VM === "1";
const LEDGER_PATH = process.env.CMUX_GALLERY_FREESTYLE_LEDGER ?? "/Users/lawrence/fun/cmuxterm-hq/.cmux-scratch/pane-protocol/gallery/freestyle-ledger.json";
/** Published matrix runs (tailnet, every member): https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix/<run>/ */
const PUBLISH_URL = "https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix";
const engines: Record<Engine, BrowserType> = { chromium, webkit };

export function parseManifest(value: unknown): MatrixCase[] {
  if (!Array.isArray(value)) throw new Error("manifest must be a JSON array");
  const ids = new Set<string>();
  return value.map((raw, index) => {
    if (!raw || typeof raw !== "object") throw new Error(`manifest case ${index} must be an object`);
    const item = raw as Record<string, unknown>;
    if (typeof item.id !== "string" || !/^[A-Za-z0-9._-]+$/.test(item.id)) throw new Error(`manifest case ${index} has an invalid id`);
    if (ids.has(item.id)) throw new Error(`manifest has duplicate id: ${item.id}`);
    ids.add(item.id);
    if (typeof item.path_or_url !== "string" || item.path_or_url.length === 0) throw new Error(`manifest case ${item.id} has an invalid path_or_url`);
    if (item.params !== undefined && (!item.params || typeof item.params !== "object" || Array.isArray(item.params))) throw new Error(`manifest case ${item.id} params must be an object`);
    const params = item.params as Record<string, unknown> | undefined;
    if (params) for (const [key, param] of Object.entries(params)) if (!["string", "number", "boolean"].includes(typeof param)) throw new Error(`manifest case ${item.id} param ${key} must be scalar`);
    return { id: item.id, path_or_url: item.path_or_url, params: params as Record<string, Scalar> | undefined };
  });
}

export function shardCases(cases: MatrixCase[], shardCount: number, shardIndex: number): MatrixCase[] {
  if (!Number.isInteger(shardCount) || shardCount < 1) throw new Error("shardCount must be a positive integer");
  if (!Number.isInteger(shardIndex) || shardIndex < 0 || shardIndex >= shardCount) throw new Error("shardIndex must be within shardCount");
  return cases.filter((_, index) => index % shardCount === shardIndex);
}

export function diffPng(actualBytes: Buffer, baselineBytes: Buffer, threshold: number): { png: Buffer; result: DiffResult } {
  const actual = PNG.sync.read(actualBytes);
  const baseline = PNG.sync.read(baselineBytes);
  const width = Math.max(actual.width, baseline.width);
  const height = Math.max(actual.height, baseline.height);
  const a = new PNG({ width, height });
  const b = new PNG({ width, height });
  PNG.bitblt(actual, a, 0, 0, actual.width, actual.height, 0, 0);
  PNG.bitblt(baseline, b, 0, 0, baseline.width, baseline.height, 0, 0);
  const diff = new PNG({ width, height });
  const differentPixels = pixelmatch(a.data, b.data, diff.data, width, height, { threshold: 0.1 });
  const totalPixels = width * height;
  const percentage = totalPixels === 0 ? 0 : (differentPixels / totalPixels) * 100;
  return { png: PNG.sync.write(diff), result: { differentPixels, totalPixels, percentage, passed: percentage <= threshold } };
}

export function readLedger(path: string): Ledger {
  return JSON.parse(readFileSync(path, "utf8")) as Ledger;
}

/** The ids an earlier run created and neither paused nor deleted (a crash, a failed cleanup). */
export function undeletedLedgerIds(path: string): string[] {
  if (!existsSync(path)) return [];
  const ledger = readLedger(path);
  return ledger.vmIds.filter((id) => !ledger.deletedVmIds.includes(id) && !(ledger.pausedVmIds ?? []).includes(id));
}

/** Pauses only IDs already recorded in the ledger, each by its exact id. No list operation. */
export async function pauseLedgerIds(path: string, pauseExact: (id: string) => Promise<void>): Promise<void> {
  const ledger = readLedger(path);
  ledger.pausedVmIds ??= [];
  let firstError: unknown;
  for (const id of ledger.vmIds) {
    if (ledger.pausedVmIds.includes(id) || ledger.deletedVmIds.includes(id)) continue;
    try {
      await pauseExact(id);
      ledger.pausedVmIds.push(id);
      writeLedger(path, ledger);
    } catch (error) {
      firstError ??= error;
    }
  }
  if (firstError) throw firstError;
}

export function writeLedger(path: string, ledger: Ledger): void {
  writeFileSync(path, `${JSON.stringify(ledger, null, 2)}\n`, { mode: 0o600 });
}

/** Deletes only IDs already recorded in the ledger. It intentionally has no list operation. */
export async function deleteLedgerIds(path: string, deleteExact: (id: string) => Promise<void>): Promise<void> {
  const ledger = readLedger(path);
  let firstError: unknown;
  for (const id of ledger.vmIds) {
    if (ledger.deletedVmIds.includes(id)) continue;
    try {
      await deleteExact(id);
      ledger.deletedVmIds.push(id);
      writeLedger(path, ledger);
    } catch (error) {
      firstError ??= error;
    }
  }
  if (firstError) throw firstError;
}

function parseEngineList(value: string): Engine[] {
  const parsed = value.split(",").filter(Boolean) as Engine[];
  if (parsed.length === 0 || parsed.some((engine) => !(engine in engines))) throw new Error(`engines must be chromium,webkit (got ${value})`);
  return [...new Set(parsed)];
}

function queryUrl(pathOrUrl: string, params: Record<string, Scalar> | undefined): string {
  const url = new URL(pathOrUrl, "http://127.0.0.1");
  // A hash route (the gallery shell, `index.html#/entry/variant?...`) carries its own query, and a
  // hash history reads the page's real query too: params there would leak into the route. Such a
  // case's params only size the viewport.
  if (!url.hash) for (const [key, value] of Object.entries(params ?? {})) url.searchParams.set(key, String(value));
  // The hash stays as written: a hash route (the gallery shell's `#/entry/variant?...`) carries
  // its own query, and the case's params go in the page's real query before it.
  return /^https?:\/\//.test(pathOrUrl) ? url.toString() : `${url.pathname}${url.search}${url.hash}`;
}

function safeFilePart(value: string): string { return value.replace(/[^A-Za-z0-9._-]+/g, "_"); }

async function serveDirectory(root: string): Promise<{ baseUrl: string; close: () => void }> {
  const contentTypes: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".wasm": "application/wasm", ".woff": "font/woff", ".ttf": "font/ttf", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".woff2": "font/woff2" };
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const requestUrl = new URL(request.url);
      const requested = decodeURIComponent(requestUrl.pathname).replace(/^\/+/, "") || "index.html";
      const file = resolve(root, requested);
      if (!file.startsWith(resolve(root))) return new Response("forbidden", { status: 403 });
      try { return new Response(await readFile(file), { headers: { "content-type": contentTypes[extname(file)] ?? "application/octet-stream" } }); } catch { return new Response("not found", { status: 404 }); }
    },
  });
  return { baseUrl: `http://127.0.0.1:${server.port}`, close: () => server.stop() };
}

async function renderCase(baseUrl: string, item: MatrixCase, engine: Engine, outputDir: string, baselineDir: string | undefined, threshold: number, browser: Browser): Promise<Record<string, unknown>> {
  const params = item.params ?? {};
  const width = Number(params.width ?? DEFAULT_WIDTH);
  const height = Number(params.height ?? DEFAULT_HEIGHT);
  const flag = (value: Scalar | undefined) => value === true || value === 1 || value === "1" || value === "true";
  // UTC and the gallery's own clock (src/gallery/clock.ts) keep times the same in every run.
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: DEFAULT_DEVICE_SCALE, colorScheme: params.colorScheme === "dark" ? "dark" : params.colorScheme === "light" ? "light" : "no-preference", locale: typeof params.locale === "string" ? params.locale : undefined, timezoneId: "UTC", reducedMotion: flag(params.reducedMotion) ? "reduce" : "no-preference", contrast: flag(params.highContrast) ? "more" : "no-preference" });
  try {
    const page = await context.newPage();
    // Play steps (webviews/src/gallery/play.ts) act through Playwright's trusted mouse and keyboard.
    await page.exposeFunction("cmuxGalleryInput", async (action: { kind: string; x?: number; y?: number; text?: string }) => {
      const at = () => page.mouse.move(action.x ?? 0, action.y ?? 0);
      if (action.kind === "click") await page.mouse.click(action.x ?? 0, action.y ?? 0);
      else if (action.kind === "hover" || action.kind === "move") await at();
      else if (action.kind === "down") { await at(); await page.mouse.down(); }
      else if (action.kind === "up") { await at(); await page.mouse.up(); }
      else if (action.kind === "type") await page.keyboard.type(action.text ?? "");
      else if (action.kind === "press") await page.keyboard.press(action.text ?? "");
    });
    const target = /^https?:\/\//.test(item.path_or_url) ? item.path_or_url : `${baseUrl}/${item.path_or_url.replace(/^\/+/, "")}`;
    const url = queryUrl(target, params);
    await page.goto(url, { waitUntil: "networkidle" });
    // A gallery stage says when it has painted and gone still (frame/main.ts `data-gallery-ready`).
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined || !document.querySelector("script[src*='gallery-frame']"), null, { timeout: 20_000 }).catch(() => undefined);
    const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady ?? null);
    // Long frames gate only on Chromium's Long Animation Frames; rAF timing in headless WebKit on a
    // CPU-only VM measures the VM's software rendering, so the stage reports it as a warning.
    const play = await page.evaluate(() => (window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport ?? null);
    // An experiment case (`measure=1`) leaves its frame timings per step (frame/experimentRunner.ts).
    const experiment = await page.evaluate(() => (window as unknown as { cmuxGalleryExperimentReport?: unknown }).cmuxGalleryExperimentReport ?? null);
    // A page that is not a stage (the gallery shell) may ask for time to settle its own frames.
    if (typeof params.settleMs === "number" && params.settleMs > 0) await page.waitForTimeout(Math.min(params.settleMs, 15_000));
    await page.evaluate((p) => { document.documentElement.dataset.galleryParams = JSON.stringify(p); }, params);
    await page.screenshot({ path: join(outputDir, `${safeFilePart(item.id)}-${engine}.png`), fullPage: true });
    const screenshotName = `${safeFilePart(item.id)}-${engine}.png`;
    const screenshotPath = join(outputDir, screenshotName);
    const result: Record<string, unknown> = { id: item.id, engine, screenshot: screenshotName, params, ready, play, ...(experiment ? { experiment } : {}) };
    if (baselineDir) {
      const baselinePath = join(baselineDir, screenshotName);
      if (existsSync(baselinePath)) {
        const { png, result: diff } = diffPng(readFileSync(screenshotPath), readFileSync(baselinePath), threshold);
        const diffName = `${safeFilePart(item.id)}-${engine}-diff.png`;
        await writeFile(join(outputDir, diffName), png);
        result.diff = diff;
        result.diffImage = diffName;
      } else result.diff = { percentage: null, passed: true, missingBaseline: true };
    }
    return result;
  } finally { await context.close(); }
}

export function renderIndex(results: Record<string, unknown>[]): string {
  const withLatency = results.map((result) => {
    const play = result.play;
    if (!play || typeof play !== "object" || !Array.isArray((play as { steps?: unknown }).steps)) return result;
    const steps = (play as { steps: unknown[] }).steps;
    const latency = settleSummary(steps.map((step) => step && typeof step === "object" ? (step as { settleMs?: unknown }).settleMs : undefined));
    return latency.count ? { ...result, latency } : result;
  });
  const data = JSON.stringify(withLatency).replace(/</g, "\\u003c");
  return `<!doctype html><meta charset="utf-8"><title>cmux gallery matrix</title><style>body{font:14px system-ui;margin:24px;background:#f5f5f5;color:#222}header{position:sticky;top:0;background:#f5f5f5;padding:8px 0;z-index:2}label{margin-right:12px}select{margin-left:4px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:16px}.card{background:white;padding:10px;border-radius:8px;box-shadow:0 1px 4px #0002}.card img{width:100%;image-rendering:auto}.meta{display:flex;justify-content:space-between;gap:8px}.diff{color:#a11}.pass{color:#176b2c}.cell{font-size:12px;margin-right:8px}.cell.fail{color:#a11}.cell.warn{color:#9a6700}.cell.pass{color:#176b2c}.play pre{font-size:11px;white-space:pre-wrap}</style><header><strong>cmux gallery matrix</strong> <span id="count"></span><label>entry <select data-filter="entry"><option value="">all</option></select></label><label>variant <select data-filter="variant"><option value="">all</option></select></label><label>locale <select data-filter="locale"><option value="">all</option></select></label><label>theme <select data-filter="theme"><option value="">all</option></select></label><label>engine <select data-filter="engine"><option value="">all</option></select></label></header><main class="grid" id="grid"></main><script>const results=${data};function playCells(result){const p=result.play;if(!p||!p.steps)return '';const cls=p.steps.reduce((s,x)=>s+x.layoutShift,0);const frames=p.steps.flatMap(x=>x.longFrames);const raf=p.steps.some(x=>x.frameSource==='raf');const fail=!raf&&frames.some(f=>f>33);const shift=p.steps.some(x=>x.problems.some(m=>m.startsWith('layout')||m.startsWith('anchor')));const latency=result.latency;const cell=(name,state,text)=>'<span class="cell '+state+'">'+name+': '+state+' '+text+'</span>';const latencyCell=latency?.count?cell('settle','pass',latency.p50.toFixed(1)+' / '+latency.p95.toFixed(1)+' / '+latency.max.toFixed(1)+' ms ('+latency.count+')'):'';const detail=p.steps.map(x=>x.status+' '+x.step+(x.problems.length?': '+x.problems.join('; '):'')).join('\\n');return '<details class="play"><summary>'+cell('layout shift',shift?'fail':'pass','CLS '+cls.toFixed(3))+' '+cell('long frames',fail?'fail':frames.length?'warn':'pass',frames.length+(frames.length?' (max '+Math.max(...frames).toFixed(1)+' ms)':'')+(raf?' · software-rendered, not a gate':''))+(latencyCell?' '+latencyCell:'')+'</summary><pre>'+detail.replace(/</g,'&lt;')+(p.error?'\\n'+p.error:'')+'</pre></details>'}const filters=[...document.querySelectorAll('select')];const values=(key)=>[...new Set(results.map(r=>r.params?.[key]??(key==='engine'?r.engine:'' )).filter(Boolean))].sort();for(const s of filters){for(const v of values(s.dataset.filter)){const o=document.createElement('option');o.value=v;o.textContent=v;s.append(o)}s.onchange=render}function render(){const active=Object.fromEntries(filters.map(s=>[s.dataset.filter,s.value]));const shown=results.filter(r=>Object.entries(active).every(([k,v])=>!v||String(k==='engine'?r.engine:r.params?.[k]??'')===v));document.querySelector('#count').textContent=shown.length+'/'+results.length;document.querySelector('#grid').innerHTML=shown.map(r=>{const d=r.diff;return '<article class="card"><div class="meta"><strong>'+r.id+'</strong><span>'+r.engine+'</span></div><img loading="lazy" src="'+r.screenshot+'"><small>'+Object.entries(r.params||{}).map(([k,v])=>k+'='+v).join(' · ')+'</small>'+(r.diffImage?'<img loading="lazy" src="'+r.diffImage+'"><span class="'+(d.passed?'pass':'diff')+'">diff '+(d.percentage??0).toFixed(3)+'%</span>':'')+playCells(r)+'</article>'}).join('')}render();</script>`;
}

export async function runLocal(args: { manifest: string; galleryDir: string; outputDir: string; baselineDir?: string; threshold: number; engines: Engine[]; shardCount: number; shardIndex: number }, browserTypes = engines): Promise<Record<string, unknown>[]> {
  const cases = parseManifest(JSON.parse(await readFile(args.manifest, "utf8")));
  const selected = shardCases(cases, args.shardCount, args.shardIndex);
  await mkdir(args.outputDir, { recursive: true });
  const server = selected.some((item) => !/^https?:\/\//.test(item.path_or_url)) ? await serveDirectory(resolve(args.galleryDir)) : null;
  const browsers = new Map<Engine, Browser>();
  try {
    // Keep one process per engine; every case still gets a fresh context and page.
    for (const engine of args.engines) browsers.set(engine, await browserTypes[engine].launch({ headless: true, timeout: 30_000 }));
    const results: Record<string, unknown>[] = [];
    for (const item of selected)
      for (const engine of args.engines) {
        const started = Date.now();
        const result = await renderCase(server?.baseUrl ?? "", item, engine, args.outputDir, args.baselineDir, args.threshold, browsers.get(engine)!);
        console.log(`rendered ${item.id} ${engine} ready=${String(result.ready)} ${Date.now() - started}ms`);
        results.push(result);
      }
    await writeFile(join(args.outputDir, "results.json"), `${JSON.stringify(results, null, 2)}\n`);
    await writeFile(join(args.outputDir, "index.html"), renderIndex(results));
    if (results.some((r) => (r.diff as DiffResult | undefined)?.passed === false)) process.exitCode = 1;
    if (results.some((r) => (r.play as { status?: string } | null)?.status === "fail")) process.exitCode = 1;
    // A gallery stage that never reported ready (or failed to mount) is a failed case, not a picture.
    const isStage = (r: Record<string, unknown>) => selected.some((item) => item.id === r.id && item.path_or_url.startsWith("frame.html"));
    const unready = results.filter((r) => isStage(r) && r.ready !== "1");
    if (unready.length) {
      console.error(`gallery matrix: ${unready.length} case(s) not ready: ${unready.slice(0, 5).map((r) => r.id).join(", ")}`);
      process.exitCode = 1;
    }
    return results;
  } finally {
    try { await Promise.all([...browsers.values()].map((browser) => browser.close())); }
    finally { server?.close(); }
  }
}

function shellQuote(value: string): string { return `'${value.replaceAll("'", "'\\''")}'`; }

/** Finish VM allocation before its caller cleans up the recorded IDs. */
export async function createAllVms<T>(count: number, create: (shard: number) => Promise<T>): Promise<T[]> {
  const results = await Promise.allSettled(Array.from({ length: count }, (_, shard) => create(shard)));
  const failed = results.filter((result): result is PromiseRejectedResult => result.status === "rejected");
  if (failed.length) throw new AggregateError(failed.map((result) => result.reason), "Gallery VM allocation failed");
  return results.map((result) => (result as PromiseFulfilledResult<T>).value);
}

async function runFreestyle(args: { manifest: string; galleryDir: string; outputDir: string; threshold: number; engines: Engine[]; vmCount: number; snapshot: string; keyFile: string; apiUrl?: string }): Promise<void> {
  const { Freestyle } = await import("freestyle");
  // The key is read from its file and only ever sent to the Freestyle API; never printed or logged.
  const key = readFileSync(args.keyFile, "utf8").trim();
  if (!key) throw new Error("Freestyle key file is empty");
  const client = new Freestyle({ apiKey: key, baseUrl: args.apiUrl ?? "https://beta-api.freestyle.sh" });
  const cases = parseManifest(JSON.parse(await readFile(args.manifest, "utf8")));
  const runId = `gallery-${randomUUID().slice(0, 8)}`;
  // The shared Freestyle account holds other cmux work: VMs are created and deleted ONLY by the
  // exact ids this ledger records. Never delete from a list call, by name or by a prefix match.
  const ledgerPath = resolve(LEDGER_PATH);
  await mkdir(dirname(ledgerPath), { recursive: true });
  const leftover = undeletedLedgerIds(ledgerPath);
  if (leftover.length) throw new Error(`the ledger still holds ${leftover.length} undeleted VM id(s) from run ${readLedger(ledgerPath).runId}; run with --freestyle-cleanup first`);
  const ledger: Ledger = { runId, createdAt: new Date().toISOString(), vmIds: [], pausedVmIds: [], deletedVmIds: [] };
  writeLedger(ledgerPath, ledger);
  const vms: Array<{ id: string; vm: any; shard: number }> = [];
  let interrupted = false;
  const onSignal = () => { interrupted = true; };
  process.once("SIGINT", onSignal); process.once("SIGTERM", onSignal);
  const pauseExact = async (id: string) => { await (vms.find((entry) => entry.id === id)?.vm ?? client.vms.ref(id)).pause(); };
  try {
    await createAllVms(args.vmCount, async (shard) => {
      const created = await client.vms.create({ snapshotId: args.snapshot, displayName: `${runId}-${shard}`, idleTimeoutSeconds: FREESTYLE_IDLE_SECONDS, metadata: { cmux: "gallery-matrix", runId }, firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] } });
      const entry = { id: created.vmId, vm: created.vm, shard };
      vms.push(entry); ledger.vmIds.push(created.vmId); writeLedger(ledgerPath, ledger);
      console.error(`freestyle: created ${created.vmId} (shard ${shard}, run ${runId})`);
    });
    const remoteRoot = `/tmp/${runId}`;
    const source = readFileSync(new URL(import.meta.url), "utf8");
    const packageJson = readFileSync(new URL("./package.json", import.meta.url), "utf8");
    const manifest = readFileSync(args.manifest, "utf8");
    const galleryFiles: Array<{ path: string; data: Buffer }> = [];
    async function collect(dir: string) { for (const item of await readdir(dir, { withFileTypes: true })) { const path = join(dir, item.name); if (item.isDirectory()) await collect(path); else galleryFiles.push({ path: relative(resolve(args.galleryDir), path), data: readFileSync(path) }); } }
    await collect(resolve(args.galleryDir));
    // Every shard runs to the end: one shard's failure must not drop the others' pictures.
    const failures: string[] = [];
    await Promise.allSettled(vms.map(async ({ vm, shard }) => {
      await vm.fs.writeTextFile(`${remoteRoot}/runner.ts`, source, { mode: 0o644 });
      await vm.fs.writeTextFile(`${remoteRoot}/package.json`, packageJson, { mode: 0o644 });
      await vm.fs.writeTextFile(`${remoteRoot}/manifest.json`, manifest, { mode: 0o644 });
      for (const file of galleryFiles) {
        await vm.exec({ command: `mkdir -p ${shellQuote(dirname(`${remoteRoot}/gallery/${file.path}`))}`, timeoutMs: 30_000, linuxUser: "root" });
        await vm.fs.writeFile(`${remoteRoot}/gallery/${file.path}`, file.data, { mode: 0o644 });
      }
      const selected = shardCases(cases, args.vmCount, shard);
      await vm.fs.writeTextFile(`${remoteRoot}/shard.json`, `${JSON.stringify(selected)}\n`, { mode: 0o644 });
      // Two steps, each under the 5-minute exec cap: the toolchain, then the shard's screenshots.
      // Each step's output is kept beside the run (shard-<n>.log) for a failed shard.
      const steps = [
        `set -eu; cd ${shellQuote(remoteRoot)}; bun install --no-save; bunx playwright install --with-deps ${args.engines.join(" ")}`,
        // `timeout` ends the step inside the exec cap, so a slow shard still reports its log.
        `set -eu; cd ${shellQuote(remoteRoot)}; CMUX_BROWSER_TESTS=1 CMUX_GALLERY_IN_VM=1 timeout 280 bun runner.ts --manifest shard.json --gallery-dir gallery --output-dir output --engines ${args.engines.join(",")} --threshold ${args.threshold}`,
      ];
      const logPath = join(args.outputDir, `shard-${shard}.log`);
      await mkdir(args.outputDir, { recursive: true });
      for (const [index, command] of steps.entries()) {
        const result = await vm.exec({ command, timeoutMs: 300_000, linuxUser: "root" });
        await writeFile(logPath, `## step ${index + 1} exit ${result.statusCode ?? "?"}\n${result.stdout ?? ""}\n${result.stderr ?? ""}\n`, { flag: "a" });
        if (result.statusCode !== 0) {
          const failure = `Freestyle shard ${shard} step ${index + 1} failed (exit ${result.statusCode ?? "none"}); see ${logPath}`;
          failures.push(failure);
          // The render step fails on a failed check, after it wrote its results: fetch them anyway.
          if (index === 0) throw new Error(failure);
        }
      }
      await vm.exec({ command: `tar -czf ${shellQuote(`${remoteRoot}/output.tar.gz`)} -C ${shellQuote(`${remoteRoot}/output`)} .`, timeoutMs: 30_000, linuxUser: "root" });
      const archive = Buffer.from(await vm.fs.readFile(`${remoteRoot}/output.tar.gz`));
      const shardDir = join(args.outputDir, `shard-${shard}`);
      await mkdir(shardDir, { recursive: true });
      const archivePath = join(args.outputDir, `.shard-${shard}.tar.gz`);
      await writeFile(archivePath, archive);
      const extracted = spawnSync("tar", ["-xzf", archivePath, "-C", shardDir]);
      if (extracted.status !== 0) throw new Error(`could not extract Freestyle shard ${shard}`);
      await rm(archivePath, { force: true });
    })).then((settled) => {
      for (const outcome of settled)
        if (outcome.status === "rejected") failures.push(outcome.reason instanceof Error ? outcome.reason.message : String(outcome.reason));
    });
    if (interrupted) throw new Error("interrupted");
    const combined: Record<string, unknown>[] = [];
    for (let shard = 0; shard < args.vmCount; shard += 1) {
      const shardDir = `shard-${shard}`;
      if (!existsSync(join(args.outputDir, shardDir, "results.json"))) continue;
      const shardResults = JSON.parse(await readFile(join(args.outputDir, shardDir, "results.json"), "utf8")) as Record<string, unknown>[];
      for (const result of shardResults) {
        if (typeof result.screenshot === "string") result.screenshot = `${shardDir}/${result.screenshot}`;
        if (typeof result.diffImage === "string") result.diffImage = `${shardDir}/${result.diffImage}`;
        combined.push(result);
      }
    }
    await writeFile(join(args.outputDir, "results.json"), `${JSON.stringify(combined, null, 2)}\n`);
    await writeFile(join(args.outputDir, "index.html"), renderIndex(combined));
    // The run is published with its failures in it; the exit status says it failed.
    for (const failure of [...new Set(failures)]) console.error(failure);
    if (failures.length) process.exitCode = 1;
  } finally {
    try {
      await pauseLedgerIds(ledgerPath, pauseExact);
      console.error(`freestyle: paused ${ledger.vmIds.join(", ")} (run ${runId}; ledger ${ledgerPath})`);
    } catch (error) { console.error(`Freestyle pause failed: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1; }
    process.removeListener("SIGINT", onSignal); process.removeListener("SIGTERM", onSignal);
  }
}

/** Pauses the ledger's unsettled ids (exact ids only), after a crashed or failed run. */
async function cleanupLedger(keyFile: string, apiUrl?: string): Promise<void> {
  const { Freestyle } = await import("freestyle");
  const client = new Freestyle({ apiKey: readFileSync(keyFile, "utf8").trim(), baseUrl: apiUrl ?? "https://beta-api.freestyle.sh" });
  const ledgerPath = resolve(LEDGER_PATH);
  if (!existsSync(ledgerPath)) return;
  await pauseLedgerIds(ledgerPath, async (id) => { await client.vms.ref(id).pause(); });
}

/** Copies a run's output to cmux-lawrence:~/cmux-gallery/matrix/<run>/ (tailnet-only HTTPS). */
export function publishRun(outputDir: string, run: string, host = "cmux-lawrence"): string {
  if (!/^[A-Za-z0-9._-]+$/.test(run)) throw new Error("--publish-run must be a plain name");
  const made = spawnSync("ssh", ["-o", "BatchMode=yes", host, `mkdir -p cmux-gallery/matrix/${run}`], { stdio: "inherit" });
  if (made.status !== 0) throw new Error(`could not create the run folder on ${host}`);
  const copied = spawnSync("rsync", ["-a", "--delete", "--exclude", ".*", `${resolve(outputDir)}/`, `${host}:cmux-gallery/matrix/${run}/`], { stdio: "inherit" });
  if (copied.status !== 0) throw new Error(`rsync to ${host} failed`);
  return `${PUBLISH_URL}/${run}/`;
}

async function main(): Promise<void> {
  const { values } = parseArgs({ options: { "dry-run": { type: "boolean", default: false }, "publish-run": { type: "string" }, "publish-host": { type: "string", default: "cmux-lawrence" }, "freestyle-cleanup": { type: "boolean", default: false }, manifest: { type: "string" }, "gallery-dir": { type: "string" }, "output-dir": { type: "string", default: "gallery-matrix-output" }, baseline: { type: "string" }, threshold: { type: "string", default: "0" }, engines: { type: "string", default: "chromium,webkit" }, "shard-count": { type: "string", default: "1" }, "shard-index": { type: "string", default: "0" }, "freestyle-vms": { type: "string" }, "freestyle-snapshot": { type: "string", default: "freestyle/ubuntu-sm" }, "freestyle-key-file": { type: "string", default: "/Users/lawrence/.secrets/freestyle-cmux-next-dev-20261004.key" }, "freestyle-api-url": { type: "string" } } });
  if (values["freestyle-cleanup"]) return cleanupLedger(values["freestyle-key-file"], values["freestyle-api-url"]);
  if (!values.manifest || !values["gallery-dir"]) throw new Error("--manifest and --gallery-dir are required");
  if (values["dry-run"]) {
    const cases = parseManifest(JSON.parse(await readFile(values.manifest, "utf8")));
    for (const item of cases) console.log(queryUrl(item.path_or_url, item.params));
    console.error(`gallery matrix: ${cases.length} cases (dry run, no browser)`);
    return;
  }
  const publish = () => { if (values["publish-run"]) console.log(`matrix: ${publishRun(values["output-dir"], values["publish-run"], values["publish-host"])}`); };
  const threshold = Number(values.threshold); const engines = parseEngineList(values.engines); if (!Number.isFinite(threshold) || threshold < 0) throw new Error("--threshold must be a non-negative number");
  if (values["freestyle-vms"]) {
    await runFreestyle({ manifest: values.manifest, galleryDir: values["gallery-dir"], outputDir: values["output-dir"], threshold, engines, vmCount: Number(values["freestyle-vms"]), snapshot: values["freestyle-snapshot"], keyFile: values["freestyle-key-file"], apiUrl: values["freestyle-api-url"] });
    return publish();
  }
  // A browser on a developer laptop interrupts its owner: render only inside a VM (or CI, which sets
  // CMUX_GALLERY_IN_VM=1 on its runner). Use --freestyle-vms N, or --dry-run to list the cases.
  if (!IN_VM) throw new Error("the matrix renders only on Freestyle VMs or CI: pass --freestyle-vms N, or --dry-run");
  await runLocal({ manifest: values.manifest, galleryDir: values["gallery-dir"], outputDir: values["output-dir"], baselineDir: values.baseline, threshold, engines, shardCount: Number(values["shard-count"]), shardIndex: Number(values["shard-index"]) });
  publish();
}

if (import.meta.main) await main();

/** The URL a case opens (exported for the tests). */
export const stageUrlForTest = queryUrl;
