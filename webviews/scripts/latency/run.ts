#!/usr/bin/env bun
// Extend the existing production-page harness. --ci writes JSON/summary and fails closed;
// --no-fail is explicit report-only for budgets. Incomplete evidence always fails.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, webkit, type BrowserType, type CDPSession, type Page } from "playwright";
import { launchSelectedEngines, type EngineCoverage, type EngineLaunchFailure } from "./engine-selection";
import { PAGES } from "../../test/latency/actions";
import {
  BUDGET_120HZ,
  BUDGET_60HZ,
  measureAction,
  type ActionResult,
  type LatencyAction,
  type IdleResult,
  type Instrumentation,
  type MetricReader,
} from "../../test/latency/measure";
import { installLatencyProbe } from "../../test/latency/probe";
import { installPaintedFrames } from "../../test/support/paintedFrames";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const ENGINES: Array<[string, BrowserType]> = [
  ["chromium", chromium],
  ["webkit", webkit],
];
const INSTRUMENTATION = ["longTasks", "reactCommits", "cpu", "wakeups", "trace"];
export function parseOptions(args: string[]) {
  const values = new Map<string, string>();
  const flags = new Set<string>();
  for (let i = 0; i < args.length; i++) {
    if (["--ci", "--dev", "--no-fail", "--help"].includes(args[i])) flags.add(args[i]);
    else if (
      [
        "--runs",
        "--page",
        "--action",
        "--engine",
        "--cpu-throttle",
        "--json",
        "--idle-ms",
        "--base",
        "--require",
      ].includes(args[i]) &&
      args[i + 1] &&
      !args[i + 1].startsWith("--")
    )
      values.set(args[i], args[++i]);
    else throw new Error(`unknown option or missing value: ${args[i]}`);
  }
  const runs = Number(values.get("--runs") ?? 5);
  const cpuThrottle = Number(values.get("--cpu-throttle") ?? 1);
  const idleMs = Number(values.get("--idle-ms") ?? 1000);
  const required = (values.get("--require")?.split(",") ?? []) as Instrumentation[];
  if (
    !Number.isInteger(runs) ||
    runs < 1 ||
    !Number.isFinite(cpuThrottle) ||
    cpuThrottle < 1 ||
    !Number.isFinite(idleMs) ||
    idleMs < 1
  )
    throw new Error("runs, cpu-throttle and idle-ms must be positive finite values (runs an integer)");
  if (values.has("--engine") && !ENGINES.some(([name]) => name === values.get("--engine")))
    throw new Error("engine must be chromium or webkit");
  if (required.some((name) => !INSTRUMENTATION.includes(name))) throw new Error("unknown required instrumentation");
  const ci = flags.has("--ci");
  if (ci && flags.has("--dev")) throw new Error("CI evidence requires production fixtures");
  return {
    ci,
    dev: flags.has("--dev"),
    noFail: flags.has("--no-fail"),
    help: flags.has("--help"),
    runs,
    cpuThrottle,
    idleMs,
    required,
    pageFilter: values.get("--page"),
    actionFilter: values.get("--action"),
    engineFilter: values.get("--engine"),
    base: values.get("--base"),
    jsonOut: values.get("--json") ?? (ci ? path.join(webviews, "latency-results.json") : undefined),
  };
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as net.AddressInfo;
      probe.close(() => resolve(port));
    });
  });
}

async function closeServer(server: ChildProcess) {
  if (server.exitCode !== null || server.signalCode !== null) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      server.kill("SIGKILL");
      resolve();
    }, 2000);
    server.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    server.kill();
  });
}
/** A terminal colour escape (ESC [ ... m), as a server banner may wrap its port in one. */
const SGR = new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*m`, "g");

export function waitForServerReady(server: ChildProcess, port: number, timeoutMs = 30_000): Promise<void> {
  return new Promise((resolve, reject) => {
    let output = "";
    const finish = (error?: Error) => {
      clearTimeout(timer);
      server.stdout!.off("data", ready);
      server.stderr!.off("data", ready);
      server.off("error", failed);
      server.off("exit", exited);
      if (error) reject(error);
      else resolve();
    };
    const ready = (chunk: Buffer) => {
      // The banner may color the port ("127.0.0.1:" ESC[1m port ESC[22m) and arrive split across
      // chunks: match the output so far (its last 4 KB) with SGR escapes dropped, or startup times out.
      output = `${output}${String(chunk)}`.slice(-4096);
      if (output.replaceAll(SGR, "").includes(`127.0.0.1:${port}`)) finish();
    };
    const failed = (error: Error) => finish(error);
    const exited = (code: number | null) => finish(new Error(`server exited ${code}`));
    const timer = setTimeout(() => finish(new Error("server startup timed out")), timeoutMs);
    server.stdout!.on("data", ready);
    server.stderr!.on("data", ready);
    server.once("error", failed);
    server.once("exit", exited);
  });
}

async function startServer(dev: boolean) {
  const port = await freePort();
  const vp = path.join(webviews, "node_modules/.bin/vp");
  const outDir = dev ? undefined : fs.mkdtempSync(path.join(os.tmpdir(), "cmux-latency-"));
  const env = { ...process.env, ...(outDir ? { CMUX_LATENCY_OUT_DIR: outDir } : {}) };
  let server: ChildProcess | undefined;
  const close = async () => {
    if (server) await closeServer(server);
    if (outDir) fs.rmSync(outDir, { recursive: true, force: true });
  };
  try {
    if (!dev) {
      const build = spawnSync(vp, ["build", "--config", "vite.config.latency.ts"], {
        cwd: webviews,
        env,
        encoding: "utf8",
        timeout: 120_000,
      });
      if (build.status !== 0)
        throw new Error(`harness build failed: ${build.error ?? String(build.stderr).slice(-2000)}`);
    }
    server = spawn(
      vp,
      [dev ? "dev" : "preview", "--config", "vite.config.latency.ts", "--port", String(port), "--strictPort"],
      { cwd: webviews, env, stdio: ["ignore", "pipe", "pipe"] },
    );
    await waitForServerReady(server, port);
    return { base: `http://127.0.0.1:${port}`, close };
  } catch (error) {
    await close();
    throw error;
  }
}

async function metricReader(cdp: CDPSession): Promise<MetricReader> {
  await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
  return async () =>
    Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((metric) => [metric.name, metric.value]));
}
export async function sampleIdle(page: Page, durationMs: number, metrics?: MetricReader): Promise<IdleResult> {
  await page.evaluate(() => window.__latency?.dispose());
  const before = await metrics?.();
  const start = performance.now();
  // No page polling, observers, frames or probe timers run during this window.
  await new Promise((resolve) => setTimeout(resolve, durationMs));
  const sampleDurationMs = performance.now() - start;
  const after = await metrics?.();
  const cpuDurationMs = before && after ? 1000 * (after.ThreadTime - before.ThreadTime) : null;
  if (cpuDurationMs !== null && (!Number.isFinite(cpuDurationMs) || cpuDurationMs < 0))
    throw new Error("invalid idle CPU metrics");
  return {
    sampleDurationMs,
    cpuDurationMs,
    cpuPercent: cpuDurationMs === null ? null : (cpuDurationMs / sampleDurationMs) * 100,
    wakeups: null,
    dataSource: metrics ? "CDP Performance.ThreadTime (threadTicks): renderer main-thread CPU" : null,
    unsupportedReasons: {
      ...(metrics ? {} : { cpu: "renderer task CPU instrumentation unavailable for this engine" }),
      wakeups: "no real OS wakeup source attached; context switches are not wakeups",
    },
  };
}

export function actionInstrumentation(action: LatencyAction, engine: string): Instrumentation[] {
  return typeof action.requiredInstrumentation === "function"
    ? action.requiredInstrumentation(engine)
    : (action.requiredInstrumentation ?? []);
}

export function evidenceErrors(
  results: ActionResult[],
  expectedCases: string[],
  required: Instrumentation[],
): string[] {
  const errors: string[] = [];
  if (!expectedCases.length) errors.push("no cases selected");
  if (new Set(expectedCases).size !== expectedCases.length) errors.push("duplicate case IDs");
  for (const id of expectedCases)
    if (results.filter((result) => result.id === id).length !== 1) errors.push(`missing or duplicate case: ${id}`);
  for (const result of results) {
    if (!expectedCases.includes(result.id)) errors.push(`unexpected case: ${result.id}`);
    const numericErrors = (value: unknown): boolean =>
      typeof value === "number"
        ? !Number.isFinite(value) || value < 0
        : value !== null && typeof value === "object" && Object.values(value).some(numericErrors);
    if (numericErrors(result)) errors.push(`${result.id}: invalid numeric metric`);
    errors.push(...result.errors.map((error) => `${result.id}: ${error}`));
    if (
      (!result.samples.length && !result.adapterRuns?.length) ||
      !result.latencyMs ||
      Object.values(result.latencyMs).some((value) => !Number.isFinite(value))
    )
      errors.push(`${result.id}: invalid latency distribution`);
    const available = {
      longTasks: result.longTasks,
      reactCommits: result.reactCommits,
      cpu: result.idle?.cpuDurationMs,
      wakeups: result.idle?.wakeups,
      trace: result.trace?.paintMs === null ? null : result.trace,
    };
    for (const name of required)
      if (available[name] === null || available[name] === undefined)
        errors.push(`${result.id}: required ${name} unsupported`);
  }
  return errors;
}
function git(...args: string[]) {
  const result = spawnSync("git", args, { cwd: webviews, encoding: "utf8" });
  if (result.status !== 0 || !result.stdout.trim()) throw new Error(`git ${args.join(" ")} failed`);
  return result.stdout.trim();
}

export async function main(args = process.argv.slice(2)): Promise<number> {
  const options = parseOptions(args);
  if (options.help) {
    console.log(
      "latency [--ci] [--no-fail] [--engine chromium|webkit] [--runs N] [--json PATH] [--page FILTER] [--action FILTER] [--idle-ms N] [--base REF] [--require longTasks,reactCommits,cpu,wakeups,trace] [--cpu-throttle N] [--dev]",
    );
    return 0;
  }
  const engines = ENGINES.filter(([name]) => !options.engineFilter || name === options.engineFilter);
  const selectedEngines = engines.map(([name]) => name);
  const specs = PAGES.filter(
    (spec) => !options.pageFilter || spec.name.includes(options.pageFilter) || spec.path.includes(options.pageFilter),
  ).map((spec) => ({
    ...spec,
    actions: spec.actions.filter((action) => !options.actionFilter || action.name.includes(options.actionFilter)),
  }));
  const expectedCases = engines.flatMap(([engine]) =>
    specs.flatMap((spec) => spec.actions.map((action) => `${engine}/${spec.name}/${action.id ?? action.name}`)),
  );
  const results: ActionResult[] = [];
  const errors: string[] = [];
  const engineFailures: EngineLaunchFailure[] = [];
  const measuredEngines: string[] = [];
  const source = {
    repository: git("config", "--get", "remote.origin.url"),
    head: git("rev-parse", "HEAD"),
    base: options.base ? git("rev-parse", options.base) : git("merge-base", "HEAD", "origin/feat-cmux-next"),
    browsers: [] as Array<{ engine: string; version: string }>,
    runner: {
      platform: os.platform(),
      arch: os.arch(),
      hostname: os.hostname(),
      ciRunId: process.env.GITHUB_RUN_ID ?? null,
    },
    viewport: { width: 1280, height: 800 },
    mode: options.dev ? "development" : "production",
    dirty:
      spawnSync("git", ["status", "--porcelain", "--untracked-files=no"], {
        cwd: webviews,
        encoding: "utf8",
      }).stdout.trim().length > 0,
  };
  if (!expectedCases.length) throw new Error("no cases selected");
  if (options.ci && source.dirty) throw new Error("CI evidence requires a clean tracked source tree");
  const server = await startServer(options.dev);
  try {
    for (const [engineName, engine] of engines) {
      // A missing browser must be recorded as an incomplete sweep while the other
      // selected engine continues and contributes its evidence.
      const selection = await launchSelectedEngines([engineName], () => engine.launch({ headless: true }));
      engineFailures.push(...selection.failures);
      const browser = selection.launched[0]?.value;
      if (!browser) continue;
      measuredEngines.push(engineName);
      source.browsers.push({ engine: engineName, version: browser.version() });
      try {
        for (const spec of specs) {
          if (!spec.actions.length) continue;
          const context = await browser.newContext({ viewport: source.viewport, deviceScaleFactor: 1 });
          try {
            const openPage = async () => {
              const page = await context.newPage();
              page.setDefaultTimeout(5000);
              page.on("pageerror", (error) => errors.push(`${engineName}/${spec.name}: ${error.message}`));
              await page.addInitScript(installLatencyProbe);
              await installPaintedFrames(page);
              let metrics: MetricReader | undefined;
              if (engineName === "chromium") {
                const cdp = await context.newCDPSession(page);
                metrics = await metricReader(cdp);
                if (options.cpuThrottle > 1)
                  await cdp.send("Emulation.setCPUThrottlingRate", { rate: options.cpuThrottle });
              }
              return { page, metrics };
            };
            let { page, metrics } = await openPage();
            for (const action of spec.actions) {
              if (page.isClosed()) ({ page, metrics } = await openPage());
              await page.goto(`${server.base}${spec.path}`);
              await page.waitForFunction(spec.ready, undefined, { timeout: 30_000 });
              await page.evaluate(() => document.fonts.ready);
              const result = await measureAction(
                page,
                { page: spec.name, engine: engineName },
                action,
                options.runs,
                metrics,
              );
              if (!page.isClosed()) result.idle = await sampleIdle(page, options.idleMs, metrics);
              else {
                result.unsupportedReasons.cpu = "adapter failure closed the page before idle CPU sampling";
                result.unsupportedReasons.wakeups = "adapter failure closed the page before idle sampling";
              }
              results.push(result);
              errors.push(...evidenceErrors([result], [result.id], actionInstrumentation(action, engineName)));
              console.log(`${result.id} ${result.metricType}: ${JSON.stringify(result.latencyMs)}`);
            }
          } finally {
            await context.close();
          }
        }
      } finally {
        await browser.close();
      }
    }
  } catch (error) {
    errors.push(String(error));
  } finally {
    await server.close();
  }
  errors.push(...evidenceErrors(results, expectedCases, options.required));
  const coverage: EngineCoverage = {
    expectedEngines: selectedEngines,
    measuredEngines,
    expectedCount: selectedEngines.length,
    measuredCount: measuredEngines.length,
    complete: engineFailures.length === 0 && measuredEngines.length === selectedEngines.length,
  };
  for (const failure of engineFailures)
    errors.push(`engine launch failure (${failure.stage}): ${failure.engine}: ${failure.error}`);
  if (git("rev-parse", "HEAD") !== source.head) errors.push("source head changed during measurement");
  const report = {
    schemaVersion: 1,
    source,
    expectedCases,
    runs: options.runs,
    cpuThrottle: options.cpuThrottle,
    budget60: BUDGET_60HZ,
    budget120: BUDGET_120HZ,
    coverage,
    engineFailures,
    results,
    errors,
  };
  if (options.jsonOut) fs.writeFileSync(options.jsonOut, `${JSON.stringify(report, null, 2)}\n`);
  const summary = [
    "## Web UI latency (ms)",
    "",
    `Engine coverage: ${coverage.measuredCount}/${coverage.expectedCount} (${coverage.measuredEngines.join(", ") || "none"} of ${coverage.expectedEngines.join(", ")}) — ${coverage.complete ? "complete" : "INCOMPLETE"}.`,
    "",
    "| case | metric | p50 | p95 | max |",
    "| --- | --- | ---: | ---: | ---: |",
    ...results.map(
      (r) =>
        `| ${r.id} | ${r.metricType} | ${r.latencyMs?.p50.toFixed(1) ?? "missing"} | ${r.latencyMs?.p95.toFixed(1) ?? "missing"} | ${r.latencyMs?.max.toFixed(1) ?? "missing"} |`,
    ),
    "",
    ...errors.map((error) => `- ${error}`),
  ].join("\n");
  if (options.ci && process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
  if (errors.length) {
    console.error(errors.join("\n"));
    return 1;
  }
  return results.some((result) => !result.pass) && !options.noFail ? 1 : 0;
}
if (import.meta.main) {
  let code = 1;
  try {
    code = await main();
  } catch (error) {
    console.error(`latency: ${String(error)}`);
  }
  // Exit with the run: a server's child that outlives its killed parent keeps the pipes open, and
  // with them this process, until an outer timeout (a failed start hung CI runs for 30 minutes).
  process.exit(code);
}
