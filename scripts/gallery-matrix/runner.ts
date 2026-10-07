#!/usr/bin/env bun
import { chromium, webkit, type BrowserType, type Page } from "playwright";
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
export type Ledger = { runId: string; createdAt: string; vmIds: string[]; deletedVmIds: string[] };

const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 800;
const DEFAULT_DEVICE_SCALE = 2;
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
  for (const [key, value] of Object.entries(params ?? {})) url.searchParams.set(key, String(value));
  return /^https?:\/\//.test(pathOrUrl) ? url.toString() : `${url.pathname}${url.search}`;
}

function safeFilePart(value: string): string { return value.replace(/[^A-Za-z0-9._-]+/g, "_"); }

async function serveDirectory(root: string): Promise<{ baseUrl: string; close: () => void }> {
  const contentTypes: Record<string, string> = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".woff2": "font/woff2" };
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

async function renderCase(baseUrl: string, item: MatrixCase, engine: Engine, outputDir: string, baselineDir: string | undefined, threshold: number): Promise<Record<string, unknown>> {
  const params = item.params ?? {};
  const width = Number(params.width ?? DEFAULT_WIDTH);
  const height = Number(params.height ?? DEFAULT_HEIGHT);
  const browser = await engines[engine].launch({ headless: true });
  try {
    const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: DEFAULT_DEVICE_SCALE, colorScheme: params.colorScheme === "dark" ? "dark" : params.colorScheme === "light" ? "light" : "no-preference", locale: typeof params.locale === "string" ? params.locale : undefined });
    const page = await context.newPage();
    const target = /^https?:\/\//.test(item.path_or_url) ? item.path_or_url : `${baseUrl}/${item.path_or_url.replace(/^\/+/, "")}`;
    const url = queryUrl(target, params);
    await page.goto(url, { waitUntil: "networkidle" });
    await page.evaluate((p) => { document.documentElement.dataset.galleryParams = JSON.stringify(p); }, params);
    await page.screenshot({ path: join(outputDir, `${safeFilePart(item.id)}-${engine}.png`), fullPage: true });
    const screenshotName = `${safeFilePart(item.id)}-${engine}.png`;
    const screenshotPath = join(outputDir, screenshotName);
    const result: Record<string, unknown> = { id: item.id, engine, screenshot: screenshotName, params };
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
    await context.close();
    return result;
  } finally { await browser.close(); }
}

function renderIndex(results: Record<string, unknown>[]): string {
  const data = JSON.stringify(results).replace(/</g, "\\u003c");
  return `<!doctype html><meta charset="utf-8"><title>cmux gallery matrix</title><style>body{font:14px system-ui;margin:24px;background:#f5f5f5;color:#222}header{position:sticky;top:0;background:#f5f5f5;padding:8px 0;z-index:2}label{margin-right:12px}select{margin-left:4px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:16px}.card{background:white;padding:10px;border-radius:8px;box-shadow:0 1px 4px #0002}.card img{width:100%;image-rendering:auto}.meta{display:flex;justify-content:space-between;gap:8px}.diff{color:#a11}.pass{color:#176b2c}</style><header><strong>cmux gallery matrix</strong> <span id="count"></span><label>component <select data-filter="component"><option value="">all</option></select></label><label>state <select data-filter="state"><option value="">all</option></select></label><label>locale <select data-filter="locale"><option value="">all</option></select></label><label>theme <select data-filter="theme"><option value="">all</option></select></label><label>engine <select data-filter="engine"><option value="">all</option></select></label></header><main class="grid" id="grid"></main><script>const results=${data};const filters=[...document.querySelectorAll('select')];const values=(key)=>[...new Set(results.map(r=>r.params?.[key]??(key==='engine'?r.engine:'' )).filter(Boolean))].sort();for(const s of filters){for(const v of values(s.dataset.filter)){const o=document.createElement('option');o.value=v;o.textContent=v;s.append(o)}s.onchange=render}function render(){const active=Object.fromEntries(filters.map(s=>[s.dataset.filter,s.value]));const shown=results.filter(r=>Object.entries(active).every(([k,v])=>!v||String(k==='engine'?r.engine:r.params?.[k]??'')===v));document.querySelector('#count').textContent=shown.length+'/'+results.length;document.querySelector('#grid').innerHTML=shown.map(r=>{const d=r.diff;return '<article class="card"><div class="meta"><strong>'+r.id+'</strong><span>'+r.engine+'</span></div><img loading="lazy" src="'+r.screenshot+'"><small>'+Object.entries(r.params||{}).map(([k,v])=>k+'='+v).join(' · ')+'</small>'+(r.diffImage?'<img loading="lazy" src="'+r.diffImage+'"><span class="'+(d.passed?'pass':'diff')+'">diff '+(d.percentage??0).toFixed(3)+'%</span>':'')+'</article>'}).join('')}render();</script>`;
}

async function runLocal(args: { manifest: string; galleryDir: string; outputDir: string; baselineDir?: string; threshold: number; engines: Engine[]; shardCount: number; shardIndex: number }): Promise<Record<string, unknown>[]> {
  const cases = parseManifest(JSON.parse(await readFile(args.manifest, "utf8")));
  const selected = shardCases(cases, args.shardCount, args.shardIndex);
  await mkdir(args.outputDir, { recursive: true });
  const server = selected.some((item) => !/^https?:\/\//.test(item.path_or_url)) ? await serveDirectory(resolve(args.galleryDir)) : null;
  try {
    const results: Record<string, unknown>[] = [];
    for (const item of selected) for (const engine of args.engines) results.push(await renderCase(server?.baseUrl ?? "", item, engine, args.outputDir, args.baselineDir, args.threshold));
    await writeFile(join(args.outputDir, "results.json"), `${JSON.stringify(results, null, 2)}\n`);
    await writeFile(join(args.outputDir, "index.html"), renderIndex(results));
    if (results.some((r) => (r.diff as DiffResult | undefined)?.passed === false)) process.exitCode = 1;
    return results;
  } finally { server?.close(); }
}

function shellQuote(value: string): string { return `'${value.replaceAll("'", "'\\''")}'`; }

async function runFreestyle(args: { manifest: string; galleryDir: string; outputDir: string; threshold: number; engines: Engine[]; vmCount: number; snapshot: string; keyFile: string; apiUrl?: string }): Promise<void> {
  const { Freestyle } = await import("freestyle");
  const key = readFileSync(args.keyFile, "utf8").trim();
  if (!key) throw new Error("Freestyle key file is empty");
  const client = new Freestyle({ apiKey: key, baseUrl: args.apiUrl ?? "https://beta-api.freestyle.sh" });
  const cases = parseManifest(JSON.parse(await readFile(args.manifest, "utf8")));
  const runId = `gallery-${randomUUID().slice(0, 8)}`;
  const ledgerPath = resolve("/Users/lawrence/fun/cmuxterm-hq/.cmux-scratch/pane-protocol/gallery/freestyle-ledger.json");
  await mkdir(resolve("/Users/lawrence/fun/cmuxterm-hq/.cmux-scratch/pane-protocol/gallery"), { recursive: true });
  const ledger: Ledger = { runId, createdAt: new Date().toISOString(), vmIds: [], deletedVmIds: [] };
  writeLedger(ledgerPath, ledger);
  const vms: Array<{ id: string; vm: any; shard: number }> = [];
  let interrupted = false;
  const onSignal = () => { interrupted = true; };
  process.once("SIGINT", onSignal); process.once("SIGTERM", onSignal);
  const deleteExact = async (id: string) => { const handle = vms.find((entry) => entry.id === id)?.vm; if (handle) await handle.delete(); else await fetch(`${args.apiUrl ?? "https://beta-api.freestyle.sh"}/v5/vms/${encodeURIComponent(id)}`, { method: "DELETE", headers: { Authorization: `Bearer ${key}` } }); };
  try {
    await Promise.all(Array.from({ length: args.vmCount }, async (_, shard) => {
      const created = await client.vms.create({ snapshotId: args.snapshot, displayName: `${runId}-${shard}`, idleTimeoutSeconds: -1, metadata: { cmux: "gallery-matrix", runId }, firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] } });
      const entry = { id: created.vmId, vm: created.vm, shard };
      vms.push(entry); ledger.vmIds.push(created.vmId); writeLedger(ledgerPath, ledger);
    }));
    const remoteRoot = `/tmp/${runId}`;
    const source = readFileSync(new URL(import.meta.url), "utf8");
    const packageJson = readFileSync(new URL("./package.json", import.meta.url), "utf8");
    const manifest = readFileSync(args.manifest, "utf8");
    const galleryFiles: Array<{ path: string; data: Buffer }> = [];
    async function collect(dir: string) { for (const item of await readdir(dir, { withFileTypes: true })) { const path = join(dir, item.name); if (item.isDirectory()) await collect(path); else galleryFiles.push({ path: relative(resolve(args.galleryDir), path), data: readFileSync(path) }); } }
    await collect(resolve(args.galleryDir));
    await Promise.all(vms.map(async ({ vm, shard }) => {
      await vm.fs.writeTextFile(`${remoteRoot}/runner.ts`, source, { mode: 0o644 });
      await vm.fs.writeTextFile(`${remoteRoot}/package.json`, packageJson, { mode: 0o644 });
      await vm.fs.writeTextFile(`${remoteRoot}/manifest.json`, manifest, { mode: 0o644 });
      for (const file of galleryFiles) {
        await vm.exec({ command: `mkdir -p ${shellQuote(dirname(`${remoteRoot}/gallery/${file.path}`))}`, timeoutMs: 30_000, linuxUser: "root" });
        await vm.fs.writeFile(`${remoteRoot}/gallery/${file.path}`, file.data, { mode: 0o644 });
      }
      const selected = shardCases(cases, args.vmCount, shard);
      await vm.fs.writeTextFile(`${remoteRoot}/shard.json`, `${JSON.stringify(selected)}\n`, { mode: 0o644 });
      const command = `set -eu; mkdir -p ${shellQuote(remoteRoot)}/gallery; cd ${shellQuote(remoteRoot)}; bun install --no-save; bunx playwright install --with-deps chromium webkit; bun runner.ts --manifest shard.json --gallery-dir gallery --output-dir output --engines ${args.engines.join(",")} --threshold ${args.threshold}`;
      // Freestyle beta rejects exec-await timeout_ms above its 5-minute cap.
      const result = await vm.exec({ command, timeoutMs: 300_000, linuxUser: "root" });
      if (result.statusCode && result.statusCode !== 0) throw new Error(`Freestyle shard ${shard} failed with exit ${result.statusCode}: ${`${result.stdout ?? ""}${result.stderr ?? ""}`.slice(-2000)}`);
      await vm.exec({ command: `tar -czf ${shellQuote(`${remoteRoot}/output.tar.gz`)} -C ${shellQuote(`${remoteRoot}/output`)} .`, timeoutMs: 30_000, linuxUser: "root" });
      const archive = Buffer.from(await vm.fs.readFile(`${remoteRoot}/output.tar.gz`));
      const shardDir = join(args.outputDir, `shard-${shard}`);
      await mkdir(shardDir, { recursive: true });
      const archivePath = join(args.outputDir, `.shard-${shard}.tar.gz`);
      await writeFile(archivePath, archive);
      const extracted = spawnSync("tar", ["-xzf", archivePath, "-C", shardDir]);
      if (extracted.status !== 0) throw new Error(`could not extract Freestyle shard ${shard}`);
      await rm(archivePath, { force: true });
    }));
    if (interrupted) throw new Error("interrupted");
    const combined: Record<string, unknown>[] = [];
    for (let shard = 0; shard < args.vmCount; shard += 1) {
      const shardDir = `shard-${shard}`;
      const shardResults = JSON.parse(await readFile(join(args.outputDir, shardDir, "results.json"), "utf8")) as Record<string, unknown>[];
      for (const result of shardResults) {
        if (typeof result.screenshot === "string") result.screenshot = `${shardDir}/${result.screenshot}`;
        if (typeof result.diffImage === "string") result.diffImage = `${shardDir}/${result.diffImage}`;
        combined.push(result);
      }
    }
    await writeFile(join(args.outputDir, "results.json"), `${JSON.stringify(combined, null, 2)}\n`);
    await writeFile(join(args.outputDir, "index.html"), renderIndex(combined));
  } finally {
    try { await deleteLedgerIds(ledgerPath, deleteExact); } catch (error) { console.error(`Freestyle cleanup failed: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1; }
    process.removeListener("SIGINT", onSignal); process.removeListener("SIGTERM", onSignal);
  }
}

async function main(): Promise<void> {
  const { values } = parseArgs({ options: { manifest: { type: "string" }, "gallery-dir": { type: "string" }, "output-dir": { type: "string", default: "gallery-matrix-output" }, baseline: { type: "string" }, threshold: { type: "string", default: "0" }, engines: { type: "string", default: "chromium,webkit" }, "shard-count": { type: "string", default: "1" }, "shard-index": { type: "string", default: "0" }, "freestyle-vms": { type: "string" }, "freestyle-snapshot": { type: "string", default: "freestyle/ubuntu-sm" }, "freestyle-key-file": { type: "string", default: "/Users/lawrence/.secrets/freestyle-cmux-next-dev-20261004.key" }, "freestyle-api-url": { type: "string" } } });
  if (!values.manifest || !values["gallery-dir"]) throw new Error("--manifest and --gallery-dir are required");
  const threshold = Number(values.threshold); const engines = parseEngineList(values.engines); if (!Number.isFinite(threshold) || threshold < 0) throw new Error("--threshold must be a non-negative number");
  if (values["freestyle-vms"]) return runFreestyle({ manifest: values.manifest, galleryDir: values["gallery-dir"], outputDir: values["output-dir"], threshold, engines, vmCount: Number(values["freestyle-vms"]), snapshot: values["freestyle-snapshot"], keyFile: values["freestyle-key-file"], apiUrl: values["freestyle-api-url"] });
  await runLocal({ manifest: values.manifest, galleryDir: values["gallery-dir"], outputDir: values["output-dir"], baselineDir: values.baseline, threshold, engines, shardCount: Number(values["shard-count"]), shardIndex: Number(values["shard-index"]) });
}

if (import.meta.main) await main();
