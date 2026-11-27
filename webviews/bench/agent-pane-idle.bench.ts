// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// The agent pane's cost while the person does nothing (Leo, 2026-11-03: "im at 100% cpu rn"). The
// production pane (a vite build of the pane's dev entry) joins a stand-in acpmux that lists the open
// chat (TURNS finished turns) and OTHERS more chats, then sits through phases of PHASE_MS each and
// records the renderer's task time per second (CDP Performance TaskDuration) and the timer, frame
// and animation wakeups (bench/stability.ts):
//   rest       nothing arrives;
//   echo       acpmux repeats other chats' summaries unchanged (`_acpmux/session_changed`), RATE a
//              second, as a busy daemon does when it re-sends the list;
//   presence   acpmux repeats the same empty presence for the open chat, RATE a second;
//   changes    other chats really change (a newer `updatedAt`), RATE a second, as running agents do: the
//              pane draws none of them, so they must cost about as little (Lawrence, 2026-11-18: a short
//              chat's scroll dropped frames in an app with many running chats and much history).
// A pane at rest costs about nothing; a repeat that changes nothing must cost about as little.
// RESTS=n sits through n rest windows first, so work that grows with the time the pane is open shows.
// MEMORY=1 then says what the settled page holds: its JS heap after a collection, and a heap snapshot's
// self size by kind (code, strings, objects by constructor), so the share of an agent chat's renderer that
// is the page's own (about 145 MB a chat on a Mac, plans/cmux-next/ui-perf-baseline.md) can be cut.
//   bun bench/agent-pane-idle.bench.ts [turns=300] [others=200] [phaseMs=5000] [rate=20]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { CDPSession } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { perfRow } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle, settledAt } from "./stability";
import { newestPage } from "./daemonPage";

const TURNS = Number(process.argv[2] ?? 300);
const OTHERS = Number(process.argv[3] ?? 200);
const PHASE_MS = Number(process.argv[4] ?? 5000);
const RATE = Number(process.argv[5] ?? 20);
const RESTS = Number(process.env.RESTS ?? 1);
const MEMORY = process.env.MEMORY === "1";
// PROFILE=1 builds the pane unminified and prints each phase's heaviest functions by self time and by inclusive time
// (CDP Profiler), so a phase's cost names its code. The sampler runs on the renderer thread and inflates ms/s
// (rest 2.8 -> ~50), so read a cut's before/after from a run without PROFILE.
const PROFILE = process.env.PROFILE === "1";
for (const value of [TURNS, OTHERS, PHASE_MS, RATE, RESTS])
  if (!Number.isInteger(value) || value < 0) {
    console.error("usage: bun bench/agent-pane-idle.bench.ts [turns=300] [others=200] [phaseMs=5000] [rate=20]");
    process.exit(2);
  }
const webviews = path.resolve(import.meta.dir, "..");
const A = PAPERCUT_CHAT;
const FIRST_TEXT = `Answer ${TURNS}:`;
const chat = papercutEvents({ turns: TURNS, running: false });
const others = Array.from({ length: OTHERS }, (_, index) => ({
  ...chat.session,
  sessionId: `0190a000-0000-7000-8000-${(0x100000 + index).toString(16).padStart(12, "0")}`,
  title: `Other chat ${index + 1}`,
}));
const sessions = [chat.session, ...others];

const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const lastSeq = chat.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions };
    case "_acpmux/attach": {
      if (params.sessionId !== A) return { session: others[0], lastSeq: 0, events: [], hasMore: false };
      // As the daemon does: the newest `limit` events within `maxBytes` (daemonPage.ts).
      const { page, hasMore } = newestPage(chat.events, {
        limit: Number(params.limit ?? 400),
        maxBytes: params.maxBytes,
      });
      return { session: chat.session, lastSeq, events: page, hasMore };
    }
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq };
    default:
      return null;
  }
};

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of [...releases].reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));
try {
  const sockets = new Set<{ send(data: string): void }>();
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open(ws) {
        sockets.add(ws);
      },
      close(ws) {
        sockets.delete(ws);
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  releases.push(() => daemon.stop(true));
  const notify = (method: string, params: unknown) => {
    const text = JSON.stringify({ jsonrpc: "2.0", method, params });
    for (const socket of sockets) socket.send(text);
  };

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "agent-pane-idle-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false } : {}) },
    logLevel: "error",
  });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(() => statics.stop(true));
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&session=${A}`;
  const browser = await chromium.launch({
    headless: true,
  });
  releases.push(() => browser.close());
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  await addStabilityProbe(context, { boxes: false });
  const page = await context.newPage();
  const cdp = await cpuSession(page, true);
  await page.goto(url);
  await page.waitForFunction((text) => document.body.textContent?.includes(text), FIRST_TEXT, {
    timeout: 120_000,
    polling: 100,
  });
  // The pane's own settling (read-ahead, fonts, the first paints) is not idle.
  await page.waitForTimeout(3000);
  await settledAt(page);

  if (MEMORY && cdp) await printMemory(cdp);

  type Phase = { name: string; start?: () => () => void };
  const repeat = (send: (tick: number) => void) => () => {
    let tick = 0;
    const timer = setInterval(() => send(tick++), 1000 / Math.max(1, RATE));
    return () => clearInterval(timer);
  };
  const phases: Phase[] = [
    ...Array.from({ length: RESTS }, (_, index) => ({ name: index === 0 ? "rest" : `rest${index + 1}` })),
    {
      name: "echo",
      start: repeat((tick) =>
        notify("_acpmux/session_changed", { kind: "updated", session: others[tick % Math.max(1, OTHERS)] }),
      ),
    },
    {
      name: "presence",
      start: repeat(() => notify("_acpmux/presence", { sessionId: A, viewers: [] })),
    },
    {
      name: "changes",
      start: repeat((tick) => {
        const session = others[tick % Math.max(1, OTHERS)];
        notify("_acpmux/session_changed", {
          kind: "updated",
          session: { ...session, updatedAt: (Number(session?.updatedAt) || 0) + 1000 * (tick + 1) },
        });
      }),
    },
  ];
  console.log(
    `agent-pane-idle: ${TURNS} turns, ${OTHERS} other chats, ${PHASE_MS / 1000} s a phase, repeats ${RATE}/s`,
  );
  console.log("phase | renderer ms/s | wakeups/s | sources");
  for (const phase of phases) {
    if (phase.start && OTHERS === 0 && phase.name !== "presence") continue;
    if (PROFILE && cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await cdp.send("Profiler.start");
    }
    const stop = phase.start?.();
    const [quiet] = await measureIdle([{ page, cdp }], PHASE_MS);
    stop?.();
    if (PROFILE && cdp) printProfile(phase.name, (await cdp.send("Profiler.stop")).profile);
    const seconds = PHASE_MS / 1000;
    const msPerSecond = (quiet!.cpuMs ?? 0) / seconds;
    console.log(
      `${phase.name} | ${msPerSecond.toFixed(1)} | ${(quiet!.wakeups / seconds).toFixed(1)} | ${quiet!.sources.slice(0, 6).join("; ")}`,
    );
    perfRow({
      name: `agent_pane_idle.${phase.name}.cpu_ms_per_s`,
      p50: msPerSecond,
      p95: msPerSecond,
      target: 5,
      floor: 2,
      clock: "cpu",
      version: 3,
    });
    // Let the last repeat's frame land before the next phase.
    await page.waitForTimeout(500);
  }
  await context.close();
} finally {
  await release();
}

/// A phase's heaviest functions by self time, and the share of its samples each holds.
type CpuProfile = {
  nodes: { id: number; children?: number[]; callFrame: { functionName: string; url: string; lineNumber: number } }[];
  samples?: number[];
};
function printProfile(name: string, profile: CpuProfile) {
  const counts = new Map<number, number>();
  for (const id of profile.samples ?? []) counts.set(id, (counts.get(id) ?? 0) + 1);
  const total = profile.samples?.length ?? 0;
  const self = new Map<string, number>();
  for (const node of profile.nodes) {
    const frame = node.callFrame;
    if (frame.functionName === "(idle)" || frame.functionName === "(program)") continue;
    const file = frame.url.split("/").pop() ?? "";
    const key = `${frame.functionName || "(anonymous)"} ${file}:${frame.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + (counts.get(node.id) ?? 0));
  }
  const busy = [...self.values()].reduce((sum, value) => sum + value, 0);
  console.log(`  profile ${name}: ${busy} of ${total} samples busy`);
  for (const [key, value] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 15)) {
    if (value > 0) console.log(`    ${((100 * value) / Math.max(1, busy)).toFixed(1)}% ${key}`);
  }
  // Inclusive: each node's samples and its subtree's, counted once per function on a stack (recursion).
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const keyOf = (node: CpuProfile["nodes"][number]) =>
    `${node.callFrame.functionName || "(anonymous)"} ${node.callFrame.url.split("/").pop() ?? ""}:${node.callFrame.lineNumber + 1}`;
  const inclusive = new Map<string, number>();
  const walk = (id: number, onStack: Set<string>) => {
    const node = byId.get(id)!;
    const key = keyOf(node);
    const fresh = !onStack.has(key) && node.callFrame.functionName !== "(root)";
    if (fresh) onStack.add(key);
    const own = counts.get(id) ?? 0;
    const idle = node.callFrame.functionName === "(idle)" || node.callFrame.functionName === "(program)";
    if (own && !idle) for (const held of onStack) inclusive.set(held, (inclusive.get(held) ?? 0) + own);
    for (const child of node.children ?? []) walk(child, onStack);
    if (fresh) onStack.delete(key);
  };
  walk(profile.nodes[0]!.id, new Set());
  console.log(`  inclusive ${name}:`);
  for (const [key, value] of [...inclusive].sort((a, b) => b[1] - a[1]).slice(0, 30))
    if (key.includes(".js:")) console.log(`    ${((100 * value) / Math.max(1, busy)).toFixed(1)}% ${key}`);
}

/// The settled page's JS heap after a collection, and a heap snapshot's self size summed by node kind and by
/// the largest object constructors and code names.
async function printMemory(cdp: CDPSession) {
  await cdp.send("HeapProfiler.enable");
  await cdp.send("HeapProfiler.collectGarbage");
  const { usedSize, totalSize } = (await cdp.send("Runtime.getHeapUsage")) as { usedSize: number; totalSize: number };
  const mb = (bytes: number) => (bytes / 1048576).toFixed(1);
  console.log(`agent-pane-idle memory: js heap used ${mb(usedSize)} MB of ${mb(totalSize)} MB`);
  perfRow({ name: "agent_pane_idle.js_heap_mb", p50: usedSize / 1048576, p95: usedSize / 1048576, unit: "MB" });
  const chunks: string[] = [];
  const onChunk = ({ chunk }: { chunk: string }) => void chunks.push(chunk);
  cdp.on("HeapProfiler.addHeapSnapshotChunk", onChunk);
  await cdp.send("HeapProfiler.takeHeapSnapshot", { reportProgress: false });
  cdp.off("HeapProfiler.addHeapSnapshotChunk", onChunk);
  const snapshot = JSON.parse(chunks.join("")) as {
    snapshot: { meta: { node_fields: string[]; node_types: [string[], ...unknown[]] } };
    nodes: number[];
    strings: string[];
  };
  const fields = snapshot.snapshot.meta.node_fields;
  const width = fields.length;
  const at = { type: fields.indexOf("type"), name: fields.indexOf("name"), size: fields.indexOf("self_size") };
  const types = snapshot.snapshot.meta.node_types[0];
  const byType = new Map<string, number>();
  const byName = new Map<string, number>();
  let total = 0;
  for (let index = 0; index < snapshot.nodes.length; index += width) {
    const type = types[snapshot.nodes[index + at.type]!] ?? "?";
    const size = snapshot.nodes[index + at.size]!;
    total += size;
    byType.set(type, (byType.get(type) ?? 0) + size);
    if (type === "object" || type === "code" || type === "closure" || type === "native") {
      const name = `${type}:${(snapshot.strings[snapshot.nodes[index + at.name]!] ?? "").slice(0, 60)}`;
      byName.set(name, (byName.get(name) ?? 0) + size);
    }
  }
  console.log(`agent-pane-idle memory: snapshot self size ${mb(total)} MB by kind:`);
  for (const [type, size] of [...byType].sort((a, b) => b[1] - a[1]).slice(0, 10))
    console.log(`  ${mb(size).padStart(7)} MB  ${type}`);
  console.log("agent-pane-idle memory: largest names:");
  for (const [name, size] of [...byName].sort((a, b) => b[1] - a[1]).slice(0, 25))
    console.log(`  ${mb(size).padStart(7)} MB  ${name}`);
}
