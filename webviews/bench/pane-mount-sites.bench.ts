// l10n-allow-file: bench fixture prompts and replies, and benchmark output, not shipped UI.
// Mount-site costs inside one agent pane page (design/agent-pane-mount-sites.md rows 6, 8 and 9; Leo, 2026-11-22:
// "not just here, but anywhere you'd expect an agent pane to load, and anywhere you wouldn't expect but it still
// loads."). The production pane (a vite build of the pane's dev entry, as chat-switch.bench.ts builds it, with
// source maps) joins a stand-in acpmux holding CHATS chats, each a chat-sim transcript (bench/simLogs.ts, SIM) whose
// every message and tool title carries its chat's tag (`Chat7 ...`) and that ends on a turn with a subagent still
// running, so the sub-session tray and the Session Info card are drawn in every chat.
//
// A "variant" is the same pane built with one bench-side source edit (a vite transform on App.tsx, nothing under
// src/ changes; the build fails if the edited text is gone):
//   as-is        the tree as it is;
//   no-premount  `premountsChatView` is false: New Tab keeps no hidden chat view under it (row 6's "without it");
//   unkeyed      the sub-session tray (`<SubagentTray key={shownSessionId}>`) and the Session Info card
//                (`<SummaryCard key={snapshot.sessionId}>`) lose their key, so a chat switch updates them in place
//                instead of remounting them (row 9's "without it").
//
// ROW=newtab (row 6): each round opens a New Tab page (dev host `#...&newtab&new`, as the prewarmed spare) in a fresh
//   context, once per variant (as-is, no-premount, interleaved), waits until it told the host it drew
//   (`cmuxDevPaintedAt`) and nothing in the document changed for QUIET_MS, then reads: painted ms, script ms and task
//   ms since navigation (CDP Performance ScriptDuration, TaskDuration), and after a forced GC the JS heap (MB), DOM
//   nodes (CDP Nodes) and elements in the document, and how many transcript scrollers are in it (1 with the hidden
//   chat view, 0 without).
// ROW=switch (rows 8 and 9): each round opens Chat0 in a fresh context, once per variant (as-is, unkeyed,
//   interleaved), and times two switches through the host's `cmuxAcpmuxActions["chat.select"]`, from the call
//   (performance.now(), read after each frame painted):
//     kept     Chat1 is opened and left 1.2 s, then the switch back to Chat0 is timed: a chat in this page's kept tail
//              (tailCache.ts, 20 chats, 400 events);
//     outside  the switch to the oldest listed chat (Chat<CHATS-1>), which the page never read: it is past the idle
//              read-ahead's 12 newest (direct.ts READ_AHEAD_RECENT) and not in the kept tail (the round fails if the
//              stand-in saw any attach or events read of it before the call).
//   first    a row in view holds the target's tag;
//   live     the first frame after the page got the target's attach answer (first, if no attach was sent);
//   then, over the window from the call to live + 1000 ms: script ms (CDP ScriptDuration), the requests the page sent
//   the stand-in (count, by method) and the bytes of their answers (streamed `_acpmux/event` frames not counted), and,
//   from a 1 ms-sampled CPU profile mapped through the build's source maps, self ms in the tray's code
//   (acpmux/subagents/) and the card's (acpmux/summary/); and whether the tray and card elements present before the
//   call were replaced (remounted) or kept.
//   PROFILE=0 turns the sampler off (the times then carry no sampler overhead, and no tray or card self ms).
// Knobs: CPU=4 (CDP CPU throttling), SIM=<scenario|long:N|path> (default long:120), RUNNING=1 (Chat0 is cut at a turn
//   just started and streams the rest of its transcript at SIM_RATE records/s, 60 by default, to every socket
//   attached to it, from its first attach in a round), CHATS (default 30), ROUNDS (default 5), VARIANTS (comma list
//   to run a subset). One `MOUNT_SITES_JSON {...}` line per row carries every round.
// Commands (from webviews/; on the fleet: cmux-ci test --setup playwright --timeout 2400 -- 'cd webviews && ...'):
//   row 6 quiet    ROW=newtab ROUNDS=5 bun bench/pane-mount-sites.bench.ts
//   row 6 loaded   ROW=newtab ROUNDS=5 CPU=4 bun bench/pane-mount-sites.bench.ts
//   rows 8+9 quiet   ROW=switch ROUNDS=5 bun bench/pane-mount-sites.bench.ts
//   rows 8+9 loaded  ROW=switch ROUNDS=5 CPU=4 SIM=long:400 RUNNING=1 bun bench/pane-mount-sites.bench.ts
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { simChat, simLog } from "./simLogs";
import { sourceMapper } from "./sourceMapper";
import { papercutEvents } from "../test/support/papercutChat";
import { sim } from "../src/agent-session/acpmux/sim/script";
import type { EventRecord } from "../src/agent-session/acpmux/direct";

const ROW = process.env.ROW ?? "switch";
if (ROW !== "newtab" && ROW !== "switch") throw new Error("ROW must be newtab or switch");
const ROUNDS = Number(process.env.ROUNDS ?? 5);
const CPU = Number(process.env.CPU ?? 1);
const SIM = process.env.SIM ?? "long:120";
const RUNNING = process.env.RUNNING === "1";
const SIM_RATE = Number(process.env.SIM_RATE ?? 60);
const CHATS = Number(process.env.CHATS ?? 30);
const PROFILE = process.env.PROFILE !== "0";
const QUIET_MS = 1500;
const LIVE_TAIL_MS = 1000;
const SWITCH_MAX_MS = 20_000;
for (const [name, value] of [
  ["ROUNDS", ROUNDS],
  ["CPU", CPU],
  ["SIM_RATE", SIM_RATE],
  ["CHATS", CHATS],
] as const)
  if (!Number.isFinite(value) || value < 1) throw new Error(`${name} must be a number of at least 1`);
if (CHATS < 14) throw new Error("CHATS must be at least 14, so the outside chat is past the 12 read ahead");

type Variant = "as-is" | "no-premount" | "unkeyed";
const EDITS: Record<Variant, [string, string][]> = {
  "as-is": [],
  "no-premount": [["const premountsChatView = showNewTab && !harnessesOpen;", "const premountsChatView = false;"]],
  unkeyed: [
    ["<SubagentTray\n            key={shownSessionId}\n", "<SubagentTray\n"],
    ["<SummaryCard\n            key={snapshot.sessionId}\n", "<SummaryCard\n"],
  ],
};
const ROW_VARIANTS: Variant[] = ROW === "newtab" ? ["as-is", "no-premount"] : ["as-is", "unkeyed"];
const VARIANTS = process.env.VARIANTS
  ? (process.env.VARIANTS.split(",") as Variant[]).filter((one) => ROW_VARIANTS.includes(one))
  : ROW_VARIANTS;
if (VARIANTS.length === 0) throw new Error(`VARIANTS must name some of ${ROW_VARIANTS.join(", ")}`);

const webviews = path.resolve(import.meta.dir, "..");
const chatId = (index: number) => `0190a000-0000-7000-8000-${(0xfd00 + index).toString(16).padStart(12, "0")}`;
const tagOf = (index: number) => `Chat${index}`;

// The chats. Every message's first chunk and every tool title starts with the chat's tag, so a row in view says
// whose it is.
type Chat = { id: string; tag: string; session: Record<string, unknown>; events: EventRecord[]; rest: EventRecord[] };
const baseLog = simLog(SIM, "bench");
const tagged = (records: readonly EventRecord[], tag: string, sessionId: string): EventRecord[] => {
  const out = JSON.parse(JSON.stringify(records)) as EventRecord[];
  let previousChunk = false;
  for (const record of out) {
    (record as { sessionId: string }).sessionId = sessionId;
    const update = (record.msg as { params?: { update?: Record<string, any> } } | undefined)?.params?.update;
    const isChunk = record.kind === "agent_message_chunk";
    if (isChunk && !previousChunk && typeof update?.content?.text === "string")
      update.content.text = `${tag} ${update.content.text}`;
    if (record.kind === "tool_call" && typeof update?.title === "string") update.title = `${tag} ${update.title}`;
    previousChunk = isChunk;
  }
  return out;
};
/// A turn that starts a subagent and is still running, after `records`: the tray and the card have it to draw.
const subagentTail = (after: readonly EventRecord[], tag: string, sessionId: string) => {
  const b = sim("tail", "a running subagent");
  b.prompt(`${tag} find every flaky test in the repo.`);
  b.say(`${tag} has a subagent scanning the CI logs while it reads the suite.`);
  b.tool(`${tag} scan the last 50 CI logs for flaky tests`, { kind: "think", tool: "Agent", open: true });
  const built = b.build().events;
  const lastSeq = after.at(-1)?.seq ?? 0;
  const lastAt = after.at(-1)?.at ?? Date.UTC(2026, 10, 1);
  const firstAt = built[0]?.at ?? 0;
  return built.map((record, index) => ({
    ...record,
    sessionId,
    seq: lastSeq + index + 1,
    at: lastAt + 1000 + (record.at - firstAt),
  }));
};
const baseSession = papercutEvents({ turns: 0, running: false }).session;
const NOW = Date.UTC(2026, 10, 22, 12);
const chats: Chat[] = [];
for (let index = 0; index < CHATS; index += 1) {
  const id = chatId(index);
  const tag = tagOf(index);
  const all = tagged(baseLog.records, tag, id);
  let events: EventRecord[];
  let rest: EventRecord[] = [];
  if (RUNNING && index === 0) {
    const cut = simChat({ name: baseLog.name, records: all }, { running: true, restRecords: SIM_RATE * 120 });
    events = cut.served;
    rest = cut.rest;
  } else events = [...all, ...subagentTail(all, tag, id)];
  const opener = [...events].reverse().find((record) => record.kind === "user_message");
  const msg = (opener?.msg ?? {}) as { turnId?: string; promptId?: string; text?: string };
  chats.push({
    id,
    tag,
    events,
    rest,
    session: {
      ...baseSession,
      sessionId: id,
      title: `${tag} bench chat`,
      status: "running",
      turn: {
        turnId: String(msg.turnId ?? `turn-${opener?.seq}`),
        promptId: String(msg.promptId ?? `prompt-${opener?.seq}`),
        startedAt: opener?.at ?? NOW,
        prompt: String(msg.text ?? ""),
      },
      turnCount: events.filter((record) => record.kind === "user_message").length,
      // Newest first: Chat0 is the newest, Chat<CHATS-1> the oldest.
      updatedAt: NOW - index * 60_000,
      lastSeq: events.at(-1)?.seq ?? 0,
    },
  });
}
const byId = new Map(chats.map((chat) => [chat.id, chat]));
const zeroServed = chats[0]!.events.length;

// The stand-in acpmux.
type Ws = { send(data: string): unknown };
type Call = { method: string; sessionId: string; bytes: number; at: number };
let calls: Call[] = [];
const attachedTo = new Map<Ws, Set<string>>();
const stream = { timer: undefined as ReturnType<typeof setInterval> | undefined, next: 0, sent: 0, armed: false };
const stopStream = () => {
  if (stream.timer) clearInterval(stream.timer);
  stream.timer = undefined;
};
const resetChats = () => {
  stopStream();
  stream.next = 0;
  stream.sent = 0;
  stream.armed = RUNNING;
  const zero = chats[0]!;
  zero.events.length = zeroServed;
  zero.session.lastSeq = zero.events.at(-1)?.seq ?? 0;
};
const startStream = () => {
  if (!stream.armed) return;
  stream.armed = false;
  const zero = chats[0]!;
  const startedAt = Date.now();
  stream.timer = setInterval(
    () => {
      const due = Math.min(zero.rest.length, Math.floor(((Date.now() - startedAt) * SIM_RATE) / 1000) + 1);
      for (; stream.next < due; stream.next += 1) {
        const event = { ...zero.rest[stream.next]!, at: Date.now() };
        zero.events.push(event);
        zero.session.lastSeq = event.seq;
        stream.sent += 1;
        const frame = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
        for (const [ws, sessions] of attachedTo)
          if (sessions.has(zero.id))
            try {
              ws.send(frame);
            } catch {
              // Closed: the page reads the log again on its next attach.
            }
      }
      if (stream.next >= zero.rest.length) stopStream();
    },
    Math.max(4, Math.floor(1000 / SIM_RATE)),
  );
};
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  const chat = byId.get(String(params.sessionId)) ?? chats[0]!;
  const lastSeq = chat.events.at(-1)?.seq ?? 0;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: chats.map((one) => one.session) };
    case "_acpmux/attach": {
      const { page, hasMore } = newestPage(chat.events, {
        limit: Number(params.limit ?? 400),
        beforeSeq: Infinity,
        maxBytes: params.maxBytes,
      });
      return { session: chat.session, lastSeq, events: page, hasMore };
    }
    case "_acpmux/events": {
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = chat.events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
        return { events: prompts, hasMore: false, lastSeq };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newestPage(chat.events, {
          limit: Number(params.limit ?? 400),
          beforeSeq: Number(params.beforeSeq),
          maxBytes: params.maxBytes,
        });
        return { events: page, hasMore, lastSeq };
      }
      return { events: [], hasMore: false, lastSeq };
    }
    default:
      return null;
  }
};

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of [...releases].reverse())
    try {
      await stop();
    } catch {
      // Release the rest.
    }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));

const median = (values: readonly number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 0) return NaN;
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
};
const stat = (values: readonly number[], digits = 0) =>
  values.length === 0
    ? "n/a"
    : `${median(values).toFixed(digits)} [${Math.min(...values).toFixed(digits)} to ${Math.max(...values).toFixed(digits)}]`;

type Metrics = Record<string, number>;
const readMetrics = async (cdp: CDPSession): Promise<Metrics> => {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return Object.fromEntries(metrics.map((metric) => [metric.name, metric.value]));
};
type CpuProfile = {
  nodes: { id: number; callFrame: { url: string; lineNumber: number; columnNumber: number } }[];
  samples: number[];
  timeDeltas: number[];
};

try {
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open(ws) {
        attachedTo.set(ws, new Set());
      },
      close(ws) {
        attachedTo.delete(ws);
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        const sessionId = String(message.params?.sessionId ?? "");
        if (message.method === "_acpmux/attach") {
          attachedTo.get(ws)?.add(sessionId);
          if (sessionId === chats[0]!.id) startStream();
        }
        if (message.method === "_acpmux/detach") attachedTo.get(ws)?.delete(sessionId);
        if (message.id === undefined) {
          calls.push({ method: message.method, sessionId, bytes: 0, at: Date.now() });
          return;
        }
        const reply = JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: answer(message.method, message.params),
        });
        calls.push({ method: message.method, sessionId, bytes: reply.length, at: Date.now() });
        ws.send(reply);
      },
    },
  });
  releases.push(() => {
    stopStream();
    return daemon.stop(true);
  });

  // One production build per variant, with source maps (the code is the shipped minified code; the maps let the
  // profile name files).
  const { build } = await import("vite");
  const outs = new Map<Variant, string>();
  for (const variant of VARIANTS) {
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), `pane-mount-sites-${variant}-`));
    releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
    const edits = EDITS[variant];
    let applied = 0;
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      plugins: [
        {
          name: "pane-mount-sites-variant",
          enforce: "pre",
          // load, not transform: the source as it is on disk, before any other plugin (the React Compiler) reads it.
          load(id: string) {
            const file = id.split("?")[0]!;
            if (edits.length === 0 || !file.endsWith("/agent-session/acpmux/App.tsx")) return null;
            let next = fs.readFileSync(file, "utf8");
            for (const [from, to] of edits) {
              if (!next.includes(from))
                throw new Error(`variant ${variant}: App.tsx no longer holds ${JSON.stringify(from)}`);
              next = next.replace(from, to);
              applied += 1;
            }
            return next;
          },
        },
      ],
      build: { outDir: out, emptyOutDir: true, sourcemap: true },
      logLevel: "error",
    });
    if (applied !== edits.length) throw new Error(`variant ${variant}: ${applied} of ${edits.length} edits applied`);
    outs.set(variant, out);
  }
  const statics = new Map<Variant, number>();
  for (const [variant, out] of outs) {
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    releases.push(() => server.stop(true));
    statics.set(variant, server.port);
  }
  const endpoint = encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`);
  const browser = await chromium.launch({ headless: true });
  releases.push(() => browser.close());
  const openPage = async (variant: Variant, hash: string) => {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    await cdp.send("Performance.enable");
    if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
    await page.addInitScript(() => {
      const state = {
        changedAt: 0,
        attachReplies: [] as { sessionId: string; at: number }[],
        attachSent: [] as { sessionId: string; at: number }[],
      };
      (window as unknown as { __ms: typeof state }).__ms = state;
      new MutationObserver(() => (state.changedAt = performance.now())).observe(document, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
      });
      const Socket = window.WebSocket;
      window.WebSocket = class extends Socket {
        private attaches = new Map<string | number, string>();
        constructor(url: string | URL, protocols?: string | string[]) {
          super(url, protocols);
          this.addEventListener("message", (event) => {
            const reply = JSON.parse(String(event.data)) as { id?: string | number };
            const sessionId = reply.id === undefined ? undefined : this.attaches.get(reply.id);
            if (sessionId === undefined) return;
            this.attaches.delete(reply.id!);
            state.attachReplies.push({ sessionId, at: performance.now() });
          });
        }
        override send(data: Parameters<WebSocket["send"]>[0]): void {
          if (typeof data === "string") {
            const request = JSON.parse(data) as {
              id?: string | number;
              method?: string;
              params?: { sessionId?: string };
            };
            if (request.method === "_acpmux/attach" && request.id !== undefined && request.params?.sessionId) {
              this.attaches.set(request.id, request.params.sessionId);
              state.attachSent.push({ sessionId: request.params.sessionId, at: performance.now() });
            }
          }
          super.send(data);
        }
      } as typeof WebSocket;
    });
    await page.goto(`http://127.0.0.1:${statics.get(variant)}/#endpoint=${endpoint}&token=t${hash}`);
    return { context, page, cdp };
  };

  if (ROW === "newtab") {
    type NewTabRound = {
      variant: Variant;
      paintedMs: number;
      quietAtMs: number;
      scriptMs: number;
      taskMs: number;
      heapMb: number;
      nodes: number;
      elements: number;
      scrollers: number;
    };
    const rounds: NewTabRound[] = [];
    for (let round = 0; round < ROUNDS; round += 1) {
      const order = round % 2 ? [...VARIANTS].reverse() : VARIANTS;
      for (const variant of order) {
        resetChats();
        const { context, page, cdp } = await openPage(variant, "&newtab&new");
        try {
          await page.waitForFunction(
            (quiet) => {
              const painted = (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt;
              const state = (window as unknown as { __ms: { changedAt: number } }).__ms;
              return painted !== undefined && performance.now() - Math.max(painted, state.changedAt) > quiet;
            },
            QUIET_MS,
            { timeout: 120_000, polling: 100 },
          );
          const timing = await page.evaluate(() => ({
            painted: (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt ?? NaN,
            changedAt: (window as unknown as { __ms: { changedAt: number } }).__ms.changedAt,
            elements: document.getElementsByTagName("*").length,
            scrollers: document.querySelectorAll(".acpmux-scroll").length,
          }));
          const before = await readMetrics(cdp);
          await cdp.send("HeapProfiler.collectGarbage");
          const after = await readMetrics(cdp);
          rounds.push({
            variant,
            paintedMs: timing.painted,
            quietAtMs: timing.changedAt,
            scriptMs: (before.ScriptDuration ?? 0) * 1000,
            taskMs: (before.TaskDuration ?? 0) * 1000,
            heapMb: (after.JSHeapUsedSize ?? 0) / 1048576,
            nodes: after.Nodes ?? 0,
            elements: timing.elements,
            scrollers: timing.scrollers,
          });
          console.log(`round ${round + 1} ${variant}: ${JSON.stringify(rounds.at(-1))}`);
        } finally {
          await context.close();
        }
      }
    }
    console.log(`\nrow 6, New Tab page, CPU ${CPU}x, medians of ${ROUNDS} [min to max]`);
    for (const variant of VARIANTS) {
      const of = rounds.filter((round) => round.variant === variant);
      const col = (key: keyof NewTabRound, digits = 0) =>
        stat(
          of.map((round) => round[key] as number),
          digits,
        );
      console.log(
        `  ${variant.padEnd(12)} painted ${col("paintedMs")} ms, quiet from ${col("quietAtMs")} ms, script ${col("scriptMs")} ms, ` +
          `tasks ${col("taskMs")} ms, JS heap ${col("heapMb", 2)} MB, DOM nodes ${col("nodes")}, elements ${col("elements")}, ` +
          `transcript scrollers ${col("scrollers")}`,
      );
    }
    console.log(`MOUNT_SITES_JSON ${JSON.stringify({ row: 6, cpu: CPU, rounds })}`);
  } else {
    type Arm = "kept" | "outside";
    type SwitchRound = {
      variant: Variant;
      arm: Arm;
      firstMs: number;
      liveMs: number;
      attachSent: boolean;
      scriptMs: number;
      requests: number;
      bytes: number;
      methods: Record<string, number>;
      trayMs: number | null;
      cardMs: number | null;
      trayBefore: boolean;
      trayRemounted: boolean | null;
      cardBefore: boolean;
      cardRemounted: boolean | null;
    };
    const rounds: SwitchRound[] = [];
    const mappers = new Map<Variant, ReturnType<typeof sourceMapper>>();
    for (const [variant, out] of outs) mappers.set(variant, sourceMapper(out));
    const outsideIndex = CHATS - 1;
    const waitRow = async (page: Page, tag: string) =>
      page.waitForFunction(
        (tag) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroller) return false;
          const view = scroller.getBoundingClientRect();
          return [...scroller.querySelectorAll<HTMLElement>("[data-row-id]")].some((row) => {
            const box = row.getBoundingClientRect();
            return (
              box.height > 0 && box.bottom > view.top && box.top < view.bottom && row.textContent?.includes(`${tag} `)
            );
          });
        },
        tag,
        { timeout: 120_000, polling: 100 },
      );
    const select = (page: Page, id: string) =>
      page.evaluate(
        (id) =>
          (
            window as unknown as {
              cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
            }
          ).cmuxAcpmuxActions["chat.select"]!({ sessionId: id }),
        id,
      );
    const timedSwitch = async (
      variant: Variant,
      arm: Arm,
      page: Page,
      cdp: CDPSession,
      target: number,
    ): Promise<SwitchRound> => {
      const { id, tag } = chats[target]!;
      if (arm === "outside" && calls.some((call) => call.sessionId === id && /attach|events/.test(call.method)))
        throw new Error(`${tagOf(target)} was read before the switch; the outside arm is not cold`);
      calls = [];
      const scriptBefore = (await readMetrics(cdp)).ScriptDuration ?? 0;
      if (PROFILE) {
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 1000 });
        await cdp.send("Profiler.start");
      }
      const startedAt = Date.now();
      const got = await page.evaluate(
        ({ id, tag, tailMs, maxMs }) =>
          new Promise<{
            firstMs: number;
            liveMs: number;
            attachSent: boolean;
            trayBefore: boolean;
            trayRemounted: boolean | null;
            cardBefore: boolean;
            cardRemounted: boolean | null;
          }>((resolve) => {
            const ms = (
              window as unknown as {
                __ms: {
                  attachReplies: { sessionId: string; at: number }[];
                  attachSent: { sessionId: string; at: number }[];
                };
              }
            ).__ms;
            const tray = document.querySelector(".acpmux-running-tray");
            const card = document.querySelector(".acpmux-summary-card:not(.acpmux-summary-card--reserve)");
            const inView = () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
              if (!scroller) return false;
              const view = scroller.getBoundingClientRect();
              return [...scroller.querySelectorAll<HTMLElement>("[data-row-id]")].some((row) => {
                const box = row.getBoundingClientRect();
                return (
                  box.height > 0 &&
                  box.bottom > view.top &&
                  box.top < view.bottom &&
                  row.textContent?.includes(`${tag} `)
                );
              });
            };
            const t0 = performance.now();
            let first = 0;
            let live = 0;
            const remounted = (before: Element | null, selector: string) => {
              if (!before) return null;
              const now = document.querySelector(selector);
              return now ? now !== before : null;
            };
            const tick = () => {
              const now = performance.now();
              if (!first && inView()) first = now;
              const sent = ms.attachSent.some((one) => one.sessionId === id && one.at >= t0);
              const replied = ms.attachReplies.some((one) => one.sessionId === id && one.at >= t0);
              if (first && !live && (replied || (!sent && now - t0 > 3000))) live = replied ? now : first;
              if ((live && now - live >= tailMs) || now - t0 > maxMs) {
                resolve({
                  firstMs: first ? first - t0 : NaN,
                  liveMs: live ? live - t0 : NaN,
                  attachSent: sent,
                  trayBefore: Boolean(tray),
                  trayRemounted: remounted(tray, ".acpmux-running-tray"),
                  cardBefore: Boolean(card),
                  cardRemounted: remounted(card, ".acpmux-summary-card:not(.acpmux-summary-card--reserve)"),
                });
                return;
              }
              requestAnimationFrame(() => setTimeout(tick, 0));
            };
            void (
              window as unknown as {
                cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
              }
            ).cmuxAcpmuxActions["chat.select"]!({ sessionId: id });
            requestAnimationFrame(() => setTimeout(tick, 0));
          }),
        { id, tag, tailMs: LIVE_TAIL_MS, maxMs: SWITCH_MAX_MS },
      );
      const scriptAfter = (await readMetrics(cdp)).ScriptDuration ?? 0;
      let trayMs: number | null = null;
      let cardMs: number | null = null;
      if (PROFILE) {
        const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
        await cdp.send("Profiler.disable");
        const mapper = mappers.get(variant)!;
        const where = new Map<number, string>();
        for (const node of profile.nodes) {
          const url = node.callFrame.url;
          const file = url ? path.basename(new URL(url, "http://x").pathname) : "";
          where.set(
            node.id,
            file.endsWith(".js") ? mapper(file, node.callFrame.lineNumber, node.callFrame.columnNumber) : "",
          );
        }
        trayMs = 0;
        cardMs = 0;
        for (let index = 0; index < profile.samples.length; index += 1) {
          const source = where.get(profile.samples[index]!) ?? "";
          const dt = (profile.timeDeltas[index + 1] ?? 0) / 1000;
          if (source.includes("agent-session/acpmux/subagents/")) trayMs += dt;
          else if (source.includes("agent-session/acpmux/summary/")) cardMs += dt;
        }
      }
      const windowCalls = calls.filter((call) => call.at >= startedAt && call.method !== "_acpmux/event");
      const methods: Record<string, number> = {};
      for (const call of windowCalls) methods[call.method] = (methods[call.method] ?? 0) + 1;
      return {
        variant,
        arm,
        ...got,
        scriptMs: (scriptAfter - scriptBefore) * 1000,
        requests: windowCalls.length,
        bytes: windowCalls.reduce((sum, call) => sum + call.bytes, 0),
        methods,
        trayMs,
        cardMs,
      };
    };
    for (let round = 0; round < ROUNDS; round += 1) {
      const order = round % 2 ? [...VARIANTS].reverse() : VARIANTS;
      for (const variant of order) {
        for (const arm of ["kept", "outside"] as Arm[]) {
          resetChats();
          calls = [];
          const { context, page, cdp } = await openPage(variant, `&session=${chats[0]!.id}`);
          try {
            await waitRow(page, tagOf(0));
            if (arm === "kept") {
              await select(page, chats[1]!.id);
              await waitRow(page, tagOf(1));
              // fixed-wait: Chat1 is left at rest past the read-ahead delay before the switch back is timed.
              await page.waitForTimeout(1200);
              rounds.push(await timedSwitch(variant, arm, page, cdp, 0));
            } else {
              // fixed-wait: past the idle read-ahead (600 ms), so what it reads is read; the outside chat is not.
              await page.waitForTimeout(1200);
              rounds.push(await timedSwitch(variant, arm, page, cdp, outsideIndex));
            }
            console.log(`round ${round + 1} ${variant} ${arm}: ${JSON.stringify(rounds.at(-1))}`);
          } finally {
            await context.close();
          }
        }
      }
    }
    const load = `CPU ${CPU}x, SIM=${SIM}${RUNNING ? ` RUNNING=1 (Chat0 streams at ${SIM_RATE}/s)` : ""}, ${CHATS} chats`;
    console.log(`\nrows 8 and 9, chat switch in one page, ${load}, medians of ${ROUNDS} [min to max]`);
    for (const variant of VARIANTS)
      for (const arm of ["kept", "outside"] as Arm[]) {
        const of = rounds.filter((round) => round.variant === variant && round.arm === arm);
        const col = (key: keyof SwitchRound, digits = 0) =>
          stat(
            of
              .map((round) => round[key])
              .filter((value): value is number => typeof value === "number" && !Number.isNaN(value)),
            digits,
          );
        const yes = (key: keyof SwitchRound) => `${of.filter((round) => round[key] === true).length}/${of.length}`;
        const methods: Record<string, number[]> = {};
        for (const round of of)
          for (const [method, n] of Object.entries(round.methods)) (methods[method] ??= []).push(n);
        console.log(
          `  ${variant.padEnd(8)} ${arm.padEnd(8)} first ${col("firstMs")} ms, live ${col("liveMs")} ms, script ${col("scriptMs")} ms, ` +
            `requests ${col("requests")}, answer bytes ${col("bytes")}, tray self ${col("trayMs", 1)} ms, card self ${col("cardMs", 1)} ms; ` +
            `attach sent ${yes("attachSent")}, tray before ${yes("trayBefore")} remounted ${yes("trayRemounted")}, ` +
            `card before ${yes("cardBefore")} remounted ${yes("cardRemounted")}; by method ${Object.entries(methods)
              .map(([method, ns]) => `${method} ${median(ns)}`)
              .join(", ")}`,
        );
      }
    console.log(
      `MOUNT_SITES_JSON ${JSON.stringify({ row: "8+9", cpu: CPU, sim: SIM, running: RUNNING, chats: CHATS, profile: PROFILE, rounds })}`,
    );
  }
} finally {
  await release();
}
