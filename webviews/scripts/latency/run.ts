#!/usr/bin/env bun
// Interaction-latency harness (plans/cmux-next/zero-latency.md): for every page's named actions
// (test/latency/actions.ts), measures input-to-paint in headless Chromium and WebKit and fails
// when an action's visible response does not fit one frame of the display, or a long task sits
// on the input path. Builds the harness pages with the shipped production settings
// (vite.config.latency.ts) and serves them on a free port (`--dev`: the dev server instead, for
// iterating; slower, development React). The pages run on in-page mock hosts with a fixed reply
// delay, so the numbers do not depend on a backend.
//
//   bun run latency                       # every page, both engines, 5 runs per action
//   bun run latency --page diff --engine webkit --runs 3
//   bun run latency --dev                 # against the dev server (hot reload, development React)
//   bun run latency --json out.json       # machine-readable results
//   bun run latency --ci                  # scoreboard: JSON + GitHub step summary, never fails
//   bun run latency --no-fail             # report only
//   bun run latency --cpu-throttle 4      # Chromium only: a 4x slower CPU, to find the heavy actions
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, webkit, type BrowserType } from "playwright";
import { PAGES } from "../../test/latency/actions";
import { BUDGET_120HZ, BUDGET_60HZ, measureAction, type ActionResult } from "../../test/latency/measure";
import { installLatencyProbe } from "../../test/latency/probe";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const args = process.argv.slice(2);
const option = (name: string) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const ci = args.includes("--ci");
const dev = args.includes("--dev");
const noFail = ci || args.includes("--no-fail");
const runs = Number(option("--runs") ?? 5);
const pageFilter = option("--page");
const actionFilter = option("--action");
const engineFilter = option("--engine");
const cpuThrottle = Number(option("--cpu-throttle") ?? 1);
const jsonOut = option("--json") ?? (ci ? path.join(webviews, "latency-results.json") : undefined);

const ENGINES: Array<[string, BrowserType]> = [
  ["chromium", chromium],
  ["webkit", webkit],
];

async function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const probe = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as net.AddressInfo;
      probe.close(() => resolve(port));
    });
  });
}

async function startServer(): Promise<{ base: string; server: ChildProcess }> {
  const port = await freePort();
  const vp = path.join(webviews, "node_modules/.bin/vp");
  let command: string[];
  const env = { ...process.env };
  if (dev) command = ["dev", "--port", String(port), "--strictPort"];
  else {
    const outDir = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-latency-"));
    env.CMUX_LATENCY_OUT_DIR = outDir;
    const build = spawnSync(vp, ["build", "--config", "vite.config.latency.ts"], {
      cwd: webviews,
      env,
      encoding: "utf8",
    });
    if (build.status !== 0) throw new Error(`latency: harness build failed\n${String(build.stderr).slice(-2000)}`);
    command = ["preview", "--config", "vite.config.latency.ts", "--port", String(port), "--strictPort"];
  }
  const server = spawn(vp, command, { cwd: webviews, env, stdio: ["ignore", "pipe", "pipe"] });
  await new Promise<void>((resolve, reject) => {
    const onData = (chunk: Buffer) => (String(chunk).includes(`127.0.0.1:${port}`) ? resolve() : undefined);
    server.stdout!.on("data", onData);
    server.stderr!.on("data", onData);
    server.on("exit", (code) => reject(new Error(`server exited ${code}`)));
  });
  return { base: `http://127.0.0.1:${port}`, server };
}

const fmt = (value: number) => (Number.isFinite(value) ? value.toFixed(1).padStart(6) : "     -");

function table(results: ActionResult[]): string {
  const lines = [
    "engine    page            action             work p50  max   paint p50  max    gap  frames  long  60Hz  120Hz  refresh",
  ];
  for (const r of results) {
    lines.push(
      [
        r.engine.padEnd(9),
        r.page.padEnd(15),
        r.action.padEnd(18),
        fmt(r.work),
        fmt(r.maxWork),
        "  ",
        fmt(r.paint),
        fmt(r.maxPaint),
        fmt(r.frameGap),
        String(r.frames).padStart(5),
        `${r.longTaskRuns}/${r.samples.length}`.padStart(5),
        (r.pass60 ? "pass" : "FAIL").padStart(5),
        (r.pass120 ? "pass" : "FAIL").padStart(6),
        `${Math.round(1000 / r.budget)} Hz`.padStart(8),
      ].join(" "),
    );
    for (const error of r.errors.slice(0, 2)) lines.push(`          ${error}`);
  }
  return lines.join("\n");
}

function summary(results: ActionResult[]): string {
  const rows = results.map(
    (r) =>
      `| ${r.engine} | ${r.page} | ${r.action} | ${r.work.toFixed(1)} | ${r.paint.toFixed(1)} | ${r.frameGap.toFixed(1)} | ${r.longTaskRuns}/${r.samples.length} | ${r.pass60 ? "pass" : "**FAIL**"} | ${r.pass120 ? "pass" : "fail"} |`,
  );
  return [
    "## Interaction latency (input to paint, ms, median)",
    "",
    "| engine | page | action | work | paint | frame gap | long tasks | 60 Hz | 120 Hz |",
    "| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |",
    ...rows,
    "",
    `Pass: painted in the input's frame or the next (paint <= 2 frames), no dropped frame (gap <= 1.5 frames), no long task; 120 Hz also needs work <= ${BUDGET_120HZ.toFixed(1)} ms. Frame: ${BUDGET_60HZ.toFixed(1)} ms at 60 Hz. Scoreboard only: this job does not block.`,
  ].join("\n");
}

const { base, server } = await startServer();
const results: ActionResult[] = [];
try {
  for (const [engineName, engine] of ENGINES) {
    if (engineFilter && engineFilter !== engineName) continue;
    let browser;
    try {
      browser = await engine.launch({ headless: true });
    } catch (error) {
      console.warn(`latency: ${engineName} is not installed (bunx playwright install ${engineName}): ${String(error)}`);
      continue;
    }
    for (const spec of PAGES) {
      if (pageFilter && !spec.name.includes(pageFilter) && !spec.path.includes(pageFilter)) continue;
      const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
      const page = await context.newPage();
      page.setDefaultTimeout(5000);
      page.on("pageerror", (error) => console.warn(`latency: ${engineName} ${spec.name}: ${error.message}`));
      await page.addInitScript(installLatencyProbe);
      if (cpuThrottle > 1 && engineName === "chromium") {
        const cdp = await context.newCDPSession(page);
        await cdp.send("Emulation.setCPUThrottlingRate", { rate: cpuThrottle });
      }
      for (const action of spec.actions) {
        if (actionFilter && !action.name.includes(actionFilter)) continue;
        // Every action starts from a freshly loaded page, so one action's state never leaks into the next.
        await page.goto(`${base}${spec.path}`);
        await page.waitForFunction(spec.ready, undefined, { timeout: 30_000 });
        // Let the first frames settle (workers, highlighting) before measuring.
        await page.waitForTimeout(800);
        const result = await measureAction(page, { page: spec.name, engine: engineName }, action, runs);
        results.push(result);
        console.log(
          `${result.pass ? "pass" : "FAIL"} ${engineName} ${spec.name} / ${action.name}: work ${result.work.toFixed(1)} ms, paint ${result.paint.toFixed(1)} ms, frame gap ${result.frameGap.toFixed(1)} ms, long tasks ${result.longTaskRuns}/${result.samples.length}${result.errors.length ? ` (${result.errors[0]})` : ""}`,
        );
      }
      await context.close();
    }
    await browser.close();
  }
} finally {
  server.kill();
}

console.log(`\n${table(results)}`);
if (jsonOut)
  fs.writeFileSync(
    jsonOut,
    `${JSON.stringify({ budget60: BUDGET_60HZ, budget120: BUDGET_120HZ, results }, null, 2)}\n`,
  );
if (ci && process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary(results)}\n`);
const failed = results.filter((r) => !r.pass);
if (results.length === 0) {
  console.error("latency: nothing was measured");
  process.exit(noFail ? 0 : 1);
}
console.log(
  failed.length
    ? `\nlatency: ${failed.length} of ${results.length} actions over budget`
    : "\nlatency: every action fits one frame",
);
process.exit(failed.length && !noFail ? 1 : 0);
