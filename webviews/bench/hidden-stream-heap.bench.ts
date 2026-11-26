// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Does a hidden agent chat that keeps streaming grow the renderer every chat shares (cmux#45888)?
//
// The app gives its page scheme one renderer per site (CEFSwitches.processPerSitePageSchemes): every agent
// chat's document lives in one renderer, on one V8 isolate. On the nightly of 2026-11-17 that renderer held
// 2.3-2.85 GB with 6-10 chats loaded, all of them hidden and their agents running, and once it hung no chat
// took a click until the app quit. This bench opens CHATS production panes (a vite build of the pane's dev
// entry) in one Chromium launched with --process-per-site, each on its own chat of a stand-in acpmux, hides
// every chat but the last, and streams turns into every chat for MINUTES: a user message, then reply chunks
// every CHUNK_MS until a turn holds TURN_CHUNKS of them, then the next turn. Every SAMPLE_S seconds it forces
// a full collection on the shared isolate and prints its used heap and how long the collection took, so the
// rows say whether streamed chats hold memory that a collection cannot free (live growth), and what a
// collection costs as they do.
//
//   bun bench/hidden-stream-heap.bench.ts [CHATS=6] [MINUTES=8] [CHUNK_MS=60] [TURN_CHUNKS=40] [SAMPLE_S=30]
//
// Prints PERF_ROWs per sample (hidden_stream_heap.used_mb.tNs, .gc_ms.tNs) and the growth (hidden_stream_heap.growth_mb_per_min).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { diff, takeSnapshot, type Snapshot } from "./heapProbe";
import { perfRow } from "./perfRow";

const num = (name: string, fallback: number) => Number(process.env[name] ?? fallback);
const CHATS = num("CHATS", 6);
const MINUTES = num("MINUTES", 8);
const CHUNK_MS = num("CHUNK_MS", 60);
const TURN_CHUNKS = num("TURN_CHUNKS", 40);
const SAMPLE_S = num("SAMPLE_S", 30);
const webviews = path.resolve(import.meta.dir, "..");

type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Socket = { send(data: string): void };
type Chat = { id: string; events: Event[]; sockets: Set<Socket>; status: string };
const sessionId = (index: number) => `0190b000-0000-7000-8000-${(0x200000 + index).toString(16).padStart(12, "0")}`;
const chats: Chat[] = Array.from({ length: CHATS }, (_, index) => ({
  id: sessionId(index),
  events: [],
  sockets: new Set(),
  status: "running",
}));
const byId = new Map(chats.map((chat) => [chat.id, chat]));
const summary = (chat: Chat, index: number) => ({
  sessionId: chat.id,
  title: `Stream ${index + 1}`,
  agent: "claude",
  cwd: "/tmp",
  status: chat.status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: chat.events.filter((event) => event.kind === "user_message").length,
  updatedAt: chat.events.at(-1)?.at ?? Date.now(),
});
const record = (chat: Chat, dir: string, kind: string, msg: Record<string, unknown>) => {
  const event = { sessionId: chat.id, seq: chat.events.length + 1, at: Date.now(), dir, kind, msg };
  chat.events.push(event);
  const line = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
  for (const socket of chat.sockets) socket.send(line);
};
const chunk = (chat: Chat, text: string) =>
  record(chat, "in", "agent_message_chunk", {
    method: "session/update",
    params: { sessionId: chat.id, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
// A few seed turns, so each chat opens on a transcript.
for (const chat of chats) {
  for (let turn = 0; turn < 3; turn++) {
    record(chat, "mux", "user_message", { text: `Seed turn ${turn + 1}`, promptId: `seed-${turn}` });
    record(chat, "mux", "turn_started", {});
    chunk(chat, `Seed reply ${turn + 1}: the retry waits longer each time, capped at eight seconds.`);
    record(chat, "mux", "turn_result", { status: "completed" });
  }
}

const answer = (method: string, params: Record<string, unknown>, ws: Socket): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: chats.map(summary) };
    case "_acpmux/attach": {
      const chat = byId.get(String(params.sessionId)) ?? chats[0]!;
      chat.sockets.add(ws);
      return {
        session: summary(chat, chats.indexOf(chat)),
        lastSeq: chat.events.length,
        events: chat.events.slice(-400),
      };
    }
    case "_acpmux/events": {
      const chat = byId.get(String(params.sessionId));
      return { events: [], hasMore: false, lastSeq: chat?.events.length ?? 0 };
    }
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
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(
          JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}, ws) }),
        );
      },
      close(ws) {
        for (const chat of chats) chat.sockets.delete(ws);
      },
    },
  });
  releases.push(() => daemon.stop(true));
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "hidden-stream-heap-"));
  releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, minify: process.env.MINIFY !== "0" },
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
  const origin = `http://127.0.0.1:${statics.port}`;
  const urlFor = (index: number) =>
    `${origin}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&session=${sessionId(index)}`;

  const browser = await chromium.launch({ headless: true, args: ["--process-per-site", "--js-flags=--expose-gc"] });
  releases.push(() => browser.close());
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  const pages: { page: Page; cdp: CDPSession }[] = [];
  for (let index = 0; index < CHATS; index++) {
    const page = await context.newPage();
    await page.goto(urlFor(index));
    await page.waitForSelector(".acpmux-scroll", { timeout: 30_000 });
    pages.push({ page, cdp: await context.newCDPSession(page) });
  }
  // A chat tab that is not shown: its document turns hidden (CEF's WasHidden); headless keeps pages visible.
  for (const { page } of pages.slice(0, -1))
    await page.evaluate(() => {
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
      document.dispatchEvent(new Event("visibilitychange"));
    });
  const probe = pages.at(-1)!.cdp;
  const heap = async () => {
    const started = performance.now();
    await probe.send("HeapProfiler.collectGarbage");
    const gcMs = performance.now() - started;
    const usage = (await probe.send("Runtime.getHeapUsage")) as { usedSize: number; totalSize: number };
    return { usedMb: usage.usedSize / 1048576, totalMb: usage.totalSize / 1048576, gcMs };
  };

  // The stream: every chat gets a chunk every CHUNK_MS; a turn ends after TURN_CHUNKS and the next one starts.
  let chunks = 0;
  const stream = setInterval(() => {
    for (const chat of chats) {
      const inTurn = chunks % TURN_CHUNKS;
      if (inTurn === 0) {
        record(chat, "mux", "user_message", { text: `Run step ${chunks / TURN_CHUNKS + 1}`, promptId: `p-${chunks}` });
        record(chat, "mux", "turn_started", {});
      }
      chunk(chat, `Line ${chunks}: seq 1 400 printed four hundred numbers, one per line, in order, then exited 0. `);
      if (inTurn === TURN_CHUNKS - 1) record(chat, "mux", "turn_result", { status: "completed" });
    }
    chunks += 1;
  }, CHUNK_MS);
  releases.push(() => clearInterval(stream));

  // PROBE=1: heap snapshots of the shared isolate at the first sample, the middle and the end; what was made
  // between the first two and is still alive at the end is printed by constructor and by holder (heapProbe).
  const snaps: Snapshot[] = [];
  const first = await heap();
  if (process.env.PROBE === "1") snaps.push(await takeSnapshot(probe));
  console.log(
    `start used=${first.usedMb.toFixed(1)}MB gc=${first.gcMs.toFixed(0)}ms chats=${CHATS} hidden=${CHATS - 1}`,
  );
  const deadline = Date.now() + MINUTES * 60_000;
  let last = first;
  for (let sample = 1; Date.now() < deadline; sample++) {
    await new Promise((resolve) => setTimeout(resolve, SAMPLE_S * 1000));
    last = await heap();
    const events = chats[0]!.events.length;
    console.log(
      `t=${sample * SAMPLE_S}s events/chat=${events} used=${last.usedMb.toFixed(1)}MB total=${last.totalMb.toFixed(1)}MB gc=${last.gcMs.toFixed(0)}ms`,
    );
    if (process.env.PROBE === "1" && snaps.length === 1 && Date.now() >= deadline - (MINUTES * 60_000) / 2)
      snaps.push(await takeSnapshot(probe));
    perfRow({ name: `hidden_stream_heap.used_mb.t${sample * SAMPLE_S}s`, p95: last.usedMb, unit: "MB" });
    perfRow({ name: `hidden_stream_heap.gc_ms.t${sample * SAMPLE_S}s`, p95: last.gcMs, unit: "ms" });
  }
  if (process.env.PROBE === "1" && snaps.length === 2)
    diff(snaps[0]!, await takeSnapshot(probe), "streamed chats", snaps[1]);
  const minutes = MINUTES;
  console.log(
    `growth: ${(last.usedMb - first.usedMb).toFixed(1)}MB in ${minutes} min (${((last.usedMb - first.usedMb) / minutes).toFixed(1)} MB/min) across ${CHATS} chats, ${CHATS - 1} hidden`,
  );
  perfRow({ name: "hidden_stream_heap.growth_mb_per_min", p95: (last.usedMb - first.usedMb) / minutes, unit: "MB" });
} finally {
  await release();
}
