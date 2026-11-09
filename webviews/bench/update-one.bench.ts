// l10n-allow-file: benchmark output, not shipped UI.
// What one small change costs as the session list grows (Leo, 2026-11-09, on a framework critique
// whose one-label change grew about 3 ms per 1,000 rows: "add a bench that changes one row's label or
// status at 100, 1,000 and 3,000 sessions and records the frame cost. It passes only if the cost stays
// flat"; his rule, 2026-11-04: "never ... acceptable ... linear time growth degradation").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon) with SIZE more
// listed sessions (`cmuxAcpmuxMockListSize`, mockFixture.ts `listedSession`: no history, five waiting
// on the person at every size, so only the list's length grows). One field of one listed session
// changes the way the daemon tells it, one `_acpmux/session_changed` with that session's summary
// (mock.ts `changeSession`). Each change's cost is the renderer main thread's task time (Chromium's
// TaskDuration, which other processes on a busy runner do not add to) from the call until two frames
// after it have rendered, less the median of as many no-op rounds (the same two frames, no change):
// the main-thread work of one update, which a 120 Hz display needs under 8.3 ms at any size. Also counted per change: the
// components that rendered (`acpmuxPerf.renders`: the pane root, the transcript and its rows, the
// home lists and their rows), long tasks.
//   kinds    status (done -> working -> input -> done), unread, title, cost (usageStats.costUsd24h)
//   surfaces home   a new chat's home: the composer and the Waiting on you inbox (HomeLists.tsx);
//            chat   a long chat open (`loadSeed(TURNS, {light: true})`) beside the list: the change
//                   is another chat's, which this chat draws nothing of.
// Not here: the sidebar session list is native (Swift: SidebarRowFeed patches one row per frame);
// History's Costs tab reads `_acpmux/ledger` on request and on no session change; History's Waiting on
// you tab reads `_acpmux/review_queue` again only when its key moves (historyPages.ts `queueKey`). Their
// per-change cost is the pane's own per-snapshot work, which both surfaces here measure.
// Rows: update_one.<surface>.<kind>.n<SIZE> (ms p50/p95), and update_one.<surface>.<kind>.growth: the
// largest size's p50 over the smallest's, in percent, which the flat-cost rule wants near 0 (target
// FLAT_PCT, beyond the noise of a shared runner). Exits 1 when a growth is over it and FLAT=gate.
//   bun bench/update-one.bench.ts [--sizes 100,1000,3000] [--changes 40] [--turns 4000] [--surfaces home,chat]
/// <reference types="bun" />
import path from "node:path";
import { chromium, type CDPSession, type Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";
import { perfRow, TARGET_MS } from "./perfRow";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const SIZES = (flag("--sizes") ?? "100,1000,3000").split(",").map(Number);
const CHANGES = Number(flag("--changes") ?? 40);
const TURNS = Number(flag("--turns") ?? 4000);
const SURFACES = (flag("--surfaces") ?? "home,chat").split(",") as Surface[];
const KINDS = ["status", "unread", "title", "cost"] as const;
/// The growth from the smallest size to the largest that still reads as flat on a shared runner.
const FLAT_PCT = 25;
const GATE = process.env.FLAT === "gate";
const PROFILE = process.env.UPDATE_ONE_PROFILE === "1";
if (SIZES.some((size) => !Number.isInteger(size) || size < 0) || !(CHANGES > 0) || !(TURNS > 0)) {
  console.error("usage: bun bench/update-one.bench.ts [--sizes 100,1000,3000] [--changes 40] [--turns 4000]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");

type Surface = "home" | "chat";
type Kind = (typeof KINDS)[number];
type Sample = { ms: number[]; idleMs: number[]; renders: Record<string, number>; longMs: number; changes: number };

/// In the page: installs `window.__updateOne`, which makes change `round` of `kind` to a listed session
/// spread over the list (or, with `noop`, nothing) and resolves once the frame after it has rendered.
async function installChanges({ kind, size }: { kind: Kind; size: number }) {
  type MockModule = typeof import("../src/agent-session/acpmux/mock");
  type PerfModule = typeof import("../src/agent-session/acpmux/perf");
  // Served from the pane's Vite root, so the page's own modules (the live mock daemon) answer.
  const mockUrl = "/mock.ts";
  const perfUrl = "/perf.ts";
  const { MockAcpmuxSocket } = (await import(/* @vite-ignore */ mockUrl)) as MockModule;
  const { acpmuxPerf } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
  const daemon = MockAcpmuxSocket.live;
  if (!daemon) throw new Error("no mock daemon");
  const rendered = () =>
    new Promise<void>((resolve) =>
      requestAnimationFrame(() => {
        const channel = new MessageChannel();
        channel.port1.onmessage = () => {
          channel.port1.close();
          resolve();
        };
        channel.port2.postMessage(0);
      }),
    );
  const statuses = [
    { status: "running", indicator: "working" },
    { status: "waiting", indicator: "input", inputSince: Date.now() },
    { status: "idle", indicator: "done", inputSince: null },
  ];
  // Every change is a real one: a value the session does not have already, which the client would drop.
  const fields = (round: number, index: number) => {
    switch (kind) {
      case "status":
        return (current: Record<string, any>) => {
          const at = statuses.findIndex((each) => each.indicator === current.indicator);
          return statuses[(at + 1) % statuses.length]!;
        };
      case "unread":
        return (current: Record<string, any>) => ({ unread: !current.unread });
      case "title":
        return { title: `Renamed chat ${index} (${round})` };
      case "cost":
        return { usageStats: { costUsd24h: 1 + round / 100, tokens24h: 1000 + round, updatedAt: Date.now() } };
    }
  };
  let longMs = 0;
  const observer = PerformanceObserver.supportedEntryTypes?.includes("longtask")
    ? new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) longMs += entry.duration;
      })
    : undefined;
  observer?.observe({ type: "longtask" });
  (window as any).__updateOne = {
    async change(round: number, noop: boolean) {
      // Spread over the list: the newest rows, the middle and the oldest change alike.
      const index = size > 0 ? Math.floor(((((round * 7919) % 10007) + 10007) % 10007) * (size / 10007)) : 0;
      if (!noop) daemon.changeSession(`listed-${index}`, fields(round, index));
      await rendered();
      await rendered();
    },
    start() {
      acpmuxPerf.enable();
      acpmuxPerf.resetRenders();
      longMs = 0;
    },
    stop() {
      observer?.disconnect();
      return { renders: Object.fromEntries(acpmuxPerf.renders), longMs };
    },
  };
}

/// CHANGES changes of `kind`, each one's main-thread task time (Chromium's TaskDuration, which a busy
/// runner's other processes do not add to) from the call until two frames after it have rendered, and
/// as many no-op rounds (the same two frames, no change) for the floor every round pays.
async function changeRun(page: Page, cdp: CDPSession, kind: Kind, size: number): Promise<Sample> {
  const task = async () => {
    const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
    return metrics.find((metric) => metric.name === "TaskDuration")!.value * 1000;
  };
  await page.evaluate(installChanges, { kind, size });
  // Warm-up changes, unmeasured: the first change of a kind compiles its paths.
  for (let round = -3; round < 0; round += 1)
    await page.evaluate((r) => (window as any).__updateOne.change(r, false), round);
  await page.evaluate(() => (window as any).__updateOne.start());
  const profiling = PROFILE && kind === "status" && size === Math.max(...SIZES);
  if (profiling) {
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
    await cdp.send("Profiler.start");
  }
  const ms: number[] = [];
  const idleMs: number[] = [];
  for (let round = 0; round < CHANGES; round += 1) {
    for (const noop of [true, false]) {
      const before = await task();
      await page.evaluate(([r, n]) => (window as any).__updateOne.change(r, n), [round, noop] as const);
      (noop ? idleMs : ms).push((await task()) - before);
    }
  }
  if (profiling) printProfile(((await cdp.send("Profiler.stop")) as { profile: Profile }).profile, size);
  const { renders, longMs } = (await page.evaluate(() => (window as any).__updateOne.stop())) as {
    renders: Record<string, number>;
    longMs: number;
  };
  // The no-op rounds rendered nothing of the pane's own, so the renders are the changes'.
  return { ms, idleMs, renders, longMs, changes: CHANGES };
}

type Profile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number } }[];
  samples?: number[];
  timeDeltas?: number[];
};
/// UPDATE_ONE_PROFILE=1: the 20 functions with the most self time over the largest size's status changes
/// (served-module lines, not source lines; bench diagnostics, keep it off for timing comparisons).
function printProfile(profile: Profile, size: number) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const self = new Map<string, number>();
  let total = 0;
  (profile.samples ?? []).forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame || frame.functionName === "(idle)" || frame.functionName === "(program)") return;
    const ms = (profile.timeDeltas?.[index] ?? 0) / 1000;
    const file = frame.url.split("/").slice(-2).join("/").split("?")[0];
    const key = `${frame.functionName || "(anonymous)"} ${file}:${frame.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + ms);
    total += ms;
  });
  console.log(`update-one profile n=${size} busy_ms=${Math.round(total)}`);
  for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 20))
    console.log(`  ${ms.toFixed(1).padStart(8)} ms ${((ms / total) * 100).toFixed(1).padStart(5)}%  ${key}`);
}

async function openPage(page: Page, port: number, size: number, surface: Surface) {
  await page.addInitScript((count) => {
    (globalThis as { cmuxAcpmuxMockListSize?: number }).cmuxAcpmuxMockListSize = count;
  }, size);
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  if (surface === "chat") {
    const seeded = (await page.evaluate(
      (turns) => (window as any).cmuxAcpmuxDebug.loadSeed(turns, { light: true }),
      TURNS,
    )) as Record<string, any>;
    if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
    await page.locator(".acpmux-scroll").first().waitFor({ timeout: 60_000 });
  } else {
    // A new chat: its home shows the composer and the inbox of every other chat's waiting asks.
    await page.evaluate(() => (window as any).cmuxAcpmuxActions["chat.new"]({ harness: "claude" }));
    await page.locator(".acpmux-home-inbox").first().waitFor({ timeout: 60_000 });
  }
  // Let the open settle: list reads, read-ahead and fonts.
  await page.waitForTimeout(1500); // fixed-wait: the page's idle read-ahead (600 ms) and list pages land first.
}

const quantile = (values: readonly number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};
const round2 = (value: number) => Math.round(value * 100) / 100;
/// Renders per change, by component family (`row:<id>` and the like summed under `row`).
function rendersPerChange(renders: Record<string, number>, changes: number) {
  const families = new Map<string, number>();
  for (const [name, count] of Object.entries(renders)) {
    const family = name.split(":")[0]!;
    families.set(family, (families.get(family) ?? 0) + count);
  }
  const total = [...families.values()].reduce((sum, value) => sum + value, 0);
  return {
    total: round2(total / changes),
    families: Object.fromEntries([...families].map(([name, count]) => [name, round2(count / changes)])),
  };
}

// React's production build, as the app ships it (bench/wheel-tick-scaling.bench.ts does the same).
process.env.NODE_ENV = "production";
const { createServer } = await import("vite");
const vite = await createServer({
  mode: "production",
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });
type Result = { surface: Surface; kind: Kind; size: number; p50: number; p95: number; renders: number; longMs: number };
const results: Result[] = [];
let failed = false;
try {
  await vite.listen();
  await warmViteServer(vite, "/?mock");
  const { port } = vite.httpServer!.address() as { port: number };
  for (const surface of SURFACES) {
    for (const size of SIZES) {
      const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
      try {
        await openPage(page, port, size, surface);
        const cdp = await page.context().newCDPSession(page);
        await cdp.send("Performance.enable");
        for (const kind of KINDS) {
          const sample = await changeRun(page, cdp, kind, size);
          // The change's own work: its round's task time over the median no-op round's.
          const floor = quantile(sample.idleMs, 0.5);
          sample.ms = sample.ms.map((value) => Math.max(0, value - floor));
          const renders = rendersPerChange(sample.renders, sample.changes);
          const result = {
            surface,
            kind,
            size,
            p50: round2(quantile(sample.ms, 0.5)),
            p95: round2(quantile(sample.ms, 0.95)),
            renders: renders.total,
            longMs: round2(sample.longMs),
          };
          results.push(result);
          console.log(
            `${surface} ${kind} n=${size}: p50 ${result.p50} ms p95 ${result.p95} ms, renders/change ${renders.total} ${JSON.stringify(renders.families)}, long ${result.longMs} ms`,
          );
          perfRow({
            name: `update_one.${surface}.${kind}.n${size}`,
            p50: result.p50,
            p95: result.p95,
            target: TARGET_MS.frameWork,
          });
        }
      } finally {
        await page.close();
      }
    }
  }
  const smallest = Math.min(...SIZES);
  const largest = Math.max(...SIZES);
  for (const surface of SURFACES) {
    for (const kind of KINDS) {
      const of = (size: number) =>
        results.find((row) => row.surface === surface && row.kind === kind && row.size === size);
      const low = of(smallest);
      const high = of(largest);
      if (!low || !high || smallest === largest) continue;
      // A floor of 1 ms under the smallest size: a change that costs a fraction of a millisecond is
      // flat whatever its ratio.
      const growth = Math.max(0, Math.round(((high.p50 - Math.max(low.p50, 1)) / Math.max(low.p50, 1)) * 100));
      const renderGrowth = round2(high.renders - low.renders);
      console.log(
        `${surface} ${kind}: n${smallest} ${low.p50} ms -> n${largest} ${high.p50} ms (+${growth} %), renders/change ${low.renders} -> ${high.renders}`,
      );
      perfRow({ name: `update_one.${surface}.${kind}.growth`, p95: growth, unit: "%", target: FLAT_PCT, floor: 10 });
      if (growth > FLAT_PCT || renderGrowth > 0.5) {
        console.log(`  GROWS: ${surface} ${kind} is not flat from ${smallest} to ${largest} sessions`);
        failed = true;
      }
    }
  }
  console.log(`UPDATE-ONE ${JSON.stringify(results)}`);
} finally {
  await browser.close();
  await vite.close();
}
if (failed && GATE) process.exit(1);
