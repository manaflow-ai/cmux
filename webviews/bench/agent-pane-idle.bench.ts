// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// The agent pane's cost while the person does nothing (Leo, 2026-11-03: "im at 100% cpu rn"). The
// production pane (a vite build of the pane's dev entry) joins a stand-in acpmux that lists the open
// chat (TURNS finished turns) and OTHERS more chats, then sits through phases of PHASE_MS each and
// records the renderer's task time per second (CDP Performance TaskDuration) and the timer, frame
// and animation wakeups (bench/stability.ts):
//   rest       nothing arrives;
//   echo       acpmux repeats other chats' summaries unchanged (`_acpmux/session_changed`), RATE a
//              second, as a busy daemon does when it re-sends the list;
//   presence   acpmux repeats the same empty presence for the open chat, RATE a second.
// A pane at rest costs about nothing; a repeat that changes nothing must cost about as little.
// RESTS=n sits through n rest windows first, so work that grows with the time the pane is open shows.
//   bun bench/agent-pane-idle.bench.ts [turns=300] [others=200] [phaseMs=5000] [rate=20]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { perfRow } from "./perfRow";
import { addStabilityProbe, cpuSession, measureIdle, settledAt } from "./stability";

const TURNS = Number(process.argv[2] ?? 300);
const OTHERS = Number(process.argv[3] ?? 200);
const PHASE_MS = Number(process.argv[4] ?? 5000);
const RATE = Number(process.argv[5] ?? 20);
const RESTS = Number(process.env.RESTS ?? 1);
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
      const limit = Number(params.limit ?? 400);
      return { session: chat.session, lastSeq, events: chat.events.slice(-limit), hasMore: chat.events.length > limit };
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
    build: { outDir: out, emptyOutDir: true },
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
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${A}`;
  const browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
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
  ];
  console.log(
    `agent-pane-idle: ${TURNS} turns, ${OTHERS} other chats, ${PHASE_MS / 1000} s a phase, repeats ${RATE}/s`,
  );
  console.log("phase | renderer ms/s | wakeups/s | sources");
  for (const phase of phases) {
    if (phase.start && OTHERS === 0 && phase.name === "echo") continue;
    const stop = phase.start?.();
    const [quiet] = await measureIdle([{ page, cdp }], PHASE_MS);
    stop?.();
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
    });
    // Let the last repeat's frame land before the next phase.
    await page.waitForTimeout(500);
  }
  await context.close();
} finally {
  await release();
}
