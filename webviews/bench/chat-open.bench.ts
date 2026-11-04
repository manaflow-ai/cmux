// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Opening a chat, stage by stage: the production pane (a vite build of the pane's dev entry) joins a
// stand-in acpmux that holds a TURNS-turn chat, as test/support/papercutChat.ts does. Each round is a
// cold page load (a fresh browser context: no HTTP or compiled-code cache), so what comes before
// `attach` is a first launch's cost, and the stages after it are what a chat switch shares. Each round
// records, from navigation start (performance.now()):
//   attach     the stand-in answered `_acpmux/attach` (the history left the daemon);
//   firstRow   the first transcript row painted;
//   latest     the newest message ("Answer N:") painted;
//   settled    nothing moved for 400 ms after that: no long task or layout shift, and the scroller's
//              position and height unchanged.
// The stages that follow `attach` are the page's own: parse, first render and layout passes.
// Long tasks (count, total) and the layout-shift sum cover the whole load; the transcript's scroll drift
// after `latest` says how much the page still moved after the newest messages appeared.
//   [LATENCY=ms] [HOST_LATENCY=ms] bun bench/chat-open.bench.ts [rounds=7] [turns=300]
// REMOTE_TAIL=present|absent uses a cold remote chat, with PEER_CONNECT_MS=2000 delaying
// initialize independently of ordinary RPC latency. The native host snapshot is available before
// that handshake. Measures navigation and tail-request origins separately; neither is a Mac click.
// REVEAL=1 also opens an offscreen message after the chat settles, then records scroll drift
// from its first visible frame, delayed scrollIntoView calls and transcript-wide row scans.
// PROFILE=1 adds a CPU profile of one load and prints the functions with the most self time between
// navigation and the newest message plus 500 ms. The build is then unminified (so functions keep their
// names) and every timed round runs on it, so the stage times are not the production build's.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { perfRow, TARGET_MS } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
/// LATENCY=ms delays every answer, as a busy daemon or the app's bridge does (chat-switch.bench.ts):
/// the open's serial round trips before its newest message show as multiples of it.
const LATENCY = Number(process.env.LATENCY ?? 0);
/// HOST_LATENCY=ms answers the app host's read of where the chat opens (`chat.scrollAnchor.get`)
/// that late, as the app's host does over its bridge (the browser dev host refuses it at once).
const HOST_LATENCY = Number(process.env.HOST_LATENCY ?? 0);
const REMOTE_TAIL = process.env.REMOTE_TAIL;
if (REMOTE_TAIL !== undefined && REMOTE_TAIL !== "present" && REMOTE_TAIL !== "absent")
  throw new Error("REMOTE_TAIL must be present or absent");
const PEER_CONNECT_MS = REMOTE_TAIL ? Number(process.env.PEER_CONNECT_MS ?? 2000) : 0;
if (!Number.isFinite(PEER_CONNECT_MS) || PEER_CONNECT_MS < 0) throw new Error("PEER_CONNECT_MS must be non-negative");
const REVEAL = process.env.REVEAL === "1";
const REVEAL_MESSAGE = "bench-reveal";
const REVEAL_TURN = Math.max(1, TURNS - 40);
const REVEAL_ROW = `assistant-${(REVEAL_TURN - 1) * 4 + 3}`;
const webviews = path.resolve(import.meta.dir, "..");
const LATEST = `Answer ${TURNS}:`;

const { events, session } = papercutEvents({
  turns: TURNS,
  running: false,
  ...(REMOTE_TAIL ? { session: { peer: "bench-vm", createdAt: 100 } } : {}),
});
if (REVEAL) {
  const event = events.find((event) => event.seq === (REVEAL_TURN - 1) * 4 + 3)!;
  const update = (event.msg.params as { update: Record<string, unknown> }).update;
  update.messageId = REVEAL_MESSAGE;
}
let attachedAt = 0;
let attachBytes = 0;
let attachEvents = 0;
/// When each protocol call first reached the stand-in in this load (epoch ms).
let arrivals = new Map<string, number>();
let socketOpenedAt = 0;
/// Every call of this load, with when it came (ms after the socket opened), for TRACE=1.
let calls: string[] = [];
/// The newest `limit` events before `beforeSeq`, oldest first, and whether older ones remain: the page the
/// daemon answers an attach or an older-history read with.
const newest = (limit: number, beforeSeq = Infinity) => {
  const older = events.filter((event) => event.seq < beforeSeq);
  return { page: older.slice(-limit), hasMore: older.length > limit };
};
const peerSnapshot = () => ({
  sessionId: PAPERCUT_CHAT,
  qualifiedSessionId: `bench-vm/${PAPERCUT_CHAT}`,
  peer: "bench-vm",
  generation: 100,
  capturedAt: Date.UTC(2026, 10, 3),
  stale: true,
  summary: session,
  events: REMOTE_TAIL === "present" ? newest(400).page : [],
  hasMore: REMOTE_TAIL === "present" && events.length > 400,
  lastSeq: REMOTE_TAIL === "present" ? (events.at(-1)?.seq ?? 0) : 0,
});
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
      };
    case "_acpmux/peer_snapshot":
      return peerSnapshot();
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach": {
      // As the daemon does: the newest `limit` events, and hasMore while older ones remain.
      const { page, hasMore } = newest(Number(params.limit ?? 400));
      const result = { session, lastSeq: events.at(-1)?.seq ?? 0, events: page, hasMore };
      attachBytes = JSON.stringify(result).length;
      attachEvents = page.length;
      return result;
    }
    case "_acpmux/events": {
      // The prompt index (hub/paging.rs prompt_index): every prompt before `beforeSeq`, each cut to its
      // text, in one reply.
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({
            ...event,
            msg: { text: String((event.msg as { text?: string }).text ?? "") },
          }));
        return { events: prompts, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newest(Number(params.limit ?? 400), Number(params.beforeSeq));
        return { events: page, hasMore, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      return { events: [], hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    }
    default:
      return null;
  }
};

/// A bundle position back to its source file and line, from the build's source map (a VLQ decode, so
/// the bench needs no source-map package).
function sourceMapper(dir: string) {
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  type Mapped = { sources: string[]; lines: number[][][] };
  const cache = new Map<string, Mapped | null>();
  function load(file: string): Mapped | null {
    const mapFile = path.join(dir, "assets", `${file}.map`);
    if (!fs.existsSync(mapFile)) return null;
    const raw = JSON.parse(fs.readFileSync(mapFile, "utf8")) as {
      sources: string[];
      mappings: string;
    };
    let source = 0;
    let line = 0;
    let column = 0;
    const lines = raw.mappings.split(";").map((segment) => {
      let generated = 0;
      return segment
        .split(",")
        .filter(Boolean)
        .map((part) => {
          const values: number[] = [];
          let shift = 0;
          let value = 0;
          for (const char of part) {
            const digit = B64.indexOf(char);
            value += (digit & 31) << shift;
            if (digit & 32) shift += 5;
            else {
              values.push(value & 1 ? -(value >> 1) : value >> 1);
              value = 0;
              shift = 0;
            }
          }
          generated += values[0]!;
          if (values.length > 1) {
            source += values[1]!;
            line += values[2]!;
            column += values[3]!;
          }
          return [generated, source, line, column];
        });
    });
    return { sources: raw.sources, lines };
  }
  return (file: string, lineNumber: number, columnNumber: number): string => {
    if (!cache.has(file)) cache.set(file, load(file));
    const map = cache.get(file);
    const segments = map?.lines[lineNumber];
    if (!map || !segments?.length) return `${file}:${lineNumber + 1}`;
    let best = segments[0]!;
    for (const segment of segments) if (segment[0]! <= columnNumber) best = segment;
    return `${map.sources[best[1]!]?.replace(/^(\.\.\/)+/, "")}:${best[2]! + 1}`;
  };
}
const releases: [string, () => unknown][] = [];
const release = async () => {
  for (const [, stop] of releases.reverse()) await Promise.resolve(stop()).catch(() => undefined);
};

try {
  const delayedReplies = new Set<ReturnType<typeof setTimeout>>();
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open() {
        socketOpenedAt ||= Date.now();
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as {
          id?: number;
          method: string;
          params?: Record<string, unknown>;
        };
        if (!arrivals.has(message.method)) arrivals.set(message.method, Date.now());
        calls.push(`${message.method} ${Date.now() - socketOpenedAt}`);
        if (message.id === undefined) return;
        const result = answer(message.method, (message as { params?: Record<string, unknown> }).params);
        const reply = () => {
          if (message.method === "_acpmux/attach") attachedAt = Date.now();
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
        };
        const delay = LATENCY + (message.method === "initialize" ? PEER_CONNECT_MS : 0);
        // fixed-wait: controlled peer handshake latency; the daemon stops at the end of the run.
        if (delay > 0) {
          const timer = setTimeout(() => {
            delayedReplies.delete(timer);
            reply();
          }, delay);
          delayedReplies.add(timer);
        } else reply();
      },
    },
  });
  releases.push([
    "stand-in acpmux",
    () => {
      for (const timer of delayedReplies) clearTimeout(timer);
      delayedReplies.clear();
      return daemon.stop(true);
    },
  ]);

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-open-bench-"));
  releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: {
      outDir: out,
      emptyOutDir: true,
      ...(process.env.PROFILE === "1" ? { minify: false, sourcemap: true } : {}),
    },
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
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
    headless: true,
  });
  releases.push(["browser", () => browser.close()]);

  type Reveal = {
    first: number;
    settled: number;
    drift: number;
    driftPx: number;
    centers: number;
    scans: number;
  };
  type Round = {
    reveal: Reveal;
    remote: {
      tailRequested: number;
      attachReceived: number;
      reconciled: number;
      earlyTop: number;
      earlyHeight: number;
      finalTop: number;
      finalHeight: number;
      maxTopDrift: number;
      maxHeightDrift: number;
      staleAtFirstPaint: boolean;
    };
    attach: number;
    firstRow: number;
    latest: number;
    settled: number;
    longTasks: number;
    longMs: number;
    shift: number;
    drift: number;
    socket: number;
    initialize: number;
    watch: number;
    dcl: number;
    scriptKiB: number;
    scripts: string[];
    forced: {
      writes: number;
      writeMs: number;
      reads: number;
      readMs: number;
      byClass: Record<string, number>;
      log: string[];
    };
  };
  const open = async (rail = "compact"): Promise<Round> => {
    const page = await browser.newPage({
      viewport: { width: 1200, height: 800 },
      deviceScaleFactor: REVEAL ? 2 : 1,
    });
    await page.addInitScript((rail) => {
      localStorage.setItem("cmux.experiments", JSON.stringify({ "thread-minimap-layout": rail }));
    }, rail);
    await page.addInitScript(
      ([latestText, instrument, hostLatency, remoteTail, diskSnapshot]) => {
        if (hostLatency > 0)
          (window as unknown as { cmuxAcpmuxActions: Record<string, () => Promise<unknown>> }).cmuxAcpmuxActions = {
            // fixed-wait: the stand-in host's answer latency is what this run measures.
            "chat.scrollAnchor.get": () => new Promise((resolve) => setTimeout(() => resolve(null), hostLatency)),
          };
        const remote = {
          tailRequested: 0,
          attachReceived: 0,
          reconciled: 0,
          earlyTop: 0,
          earlyHeight: 0,
          finalTop: 0,
          finalHeight: 0,
          maxTopDrift: 0,
          maxHeightDrift: 0,
          staleAtFirstPaint: false,
        };
        (window as unknown as { __remoteTail: typeof remote }).__remoteTail = remote;
        if (remoteTail) {
          const host = window as unknown as {
            cmuxAcpmuxActions: Record<string, () => Promise<unknown>>;
          };
          host.cmuxAcpmuxActions = {
            ...host.cmuxAcpmuxActions,
            "chat.tail.get": async () => {
              remote.tailRequested ||= performance.now();
              return diskSnapshot;
            },
            "chat.tail": async () => null,
          };
          const Socket = window.WebSocket;
          window.WebSocket = class extends Socket {
            private attaches = new Set<string | number>();
            constructor(url: string | URL, protocols?: string | string[]) {
              super(url, protocols);
              this.addEventListener("message", (event) => {
                const reply = JSON.parse(String(event.data)) as {
                  id?: string | number;
                  result?: unknown;
                };
                if (reply.id !== undefined && this.attaches.delete(reply.id) && reply.result)
                  remote.attachReceived = performance.now();
              });
            }
            override send(data: Parameters<WebSocket["send"]>[0]): void {
              if (typeof data === "string") {
                const request = JSON.parse(data) as { id?: string | number; method?: string };
                if (request.method === "_acpmux/attach" && request.id !== undefined) this.attaches.add(request.id);
              }
              super.send(data);
            }
          } as typeof WebSocket;
        }
        const forced = {
          writes: 0,
          writeMs: 0,
          reads: 0,
          readMs: 0,
          byClass: {} as Record<string, number>,
          log: [] as string[],
        };
        (window as unknown as { __forced: typeof forced }).__forced = forced;
        // INSTRUMENT=1: scroll writes and layout reads the page makes, and the time each takes (a write
        // or read after a DOM change is where the browser lays out synchronously).
        if (instrument === true) {
          const top = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
          Object.defineProperty(Element.prototype, "scrollTop", {
            ...top,
            set(this: Element, value: number) {
              const started = performance.now();
              top.set!.call(this, value);
              forced.writes += 1;
              forced.writeMs += performance.now() - started;
              const key = String(this.className).split(" ")[0] || this.tagName;
              forced.log.push(
                `${key} to ${Math.round(value)} at ${started.toFixed(0)} ms, ${(performance.now() - started).toFixed(1)} ms`,
              );
              forced.byClass[key] = (forced.byClass[key] ?? 0) + 1;
            },
          });
          const rect = Element.prototype.getBoundingClientRect;
          Element.prototype.getBoundingClientRect = function (this: Element) {
            const started = performance.now();
            const box = rect.call(this);
            forced.reads += 1;
            forced.readMs += performance.now() - started;
            return box;
          };
        }
        // TRACE=1: when the page made its socket and each fetch went out and came back, so an idle
        // stretch before the socket names what it waited on (with the scripts' load times, below).
        const trace: string[] = [];
        (window as unknown as { __trace: string[] }).__trace = trace;
        if (instrument === "trace") {
          const Socket = window.WebSocket;
          window.WebSocket = class extends Socket {
            constructor(url: string | URL, protocols?: string | string[]) {
              trace.push(`${performance.now().toFixed(0)} socket made`);
              super(url, protocols);
              this.addEventListener("open", () => trace.push(`${performance.now().toFixed(0)} socket open`));
            }
          } as typeof WebSocket;
          const fetched = window.fetch;
          window.fetch = Object.assign((input: RequestInfo | URL, init?: RequestInit) => {
            const what = `${String(input instanceof Request ? input.url : input).replace(location.origin, "")} ${String(init?.body ?? "").slice(0, 60)}`;
            trace.push(`${performance.now().toFixed(0)} fetch ${what}`);
            return fetched(input, init).finally(() => trace.push(`${performance.now().toFixed(0)} fetched ${what}`));
          }, fetched);
        }
        const state = {
          firstRow: 0,
          latest: 0,
          activity: 0,
          longTasks: 0,
          longMs: 0,
          shift: 0,
          top: -1,
          drift: 0,
        };
        (window as unknown as { __open: typeof state }).__open = state;
        const afterPaint = (done: () => void) => requestAnimationFrame(() => setTimeout(done, 0));
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            state.longTasks += 1;
            state.longMs += entry.duration;
            state.activity = Math.max(state.activity, entry.startTime + entry.duration);
          }
        }).observe({ type: "longtask", buffered: true });
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries() as unknown as {
            value: number;
            hadRecentInput: boolean;
            startTime: number;
          }[]) {
            if (entry.hadRecentInput) continue;
            state.shift += entry.value;
            state.activity = Math.max(state.activity, entry.startTime);
          }
        }).observe({ type: "layout-shift", buffered: true });
        const tick = () => {
          const now = performance.now();
          if (!state.firstRow && document.querySelector("[data-row-id]"))
            afterPaint(() => (state.firstRow ||= performance.now()));
          if (!state.latest && document.body.textContent?.includes(latestText)) {
            // TRACE=1: how much the first frame with the newest message drew.
            if (instrument === "trace") {
              const count = (selector: string) => document.querySelectorAll(selector).length;
              trace.push(
                `${now.toFixed(0)} drawn: ${count("[data-row-id]")} rows, ${count(".acpmux-minimap__entry")} rail entries, ${count("*")} elements, ${count(".acpmux-composer *, .acpmux-header *")} in composer and header`,
              );
            }
            afterPaint(() => {
              if (state.latest) return;
              state.latest = performance.now();
              const scroll = document.querySelector<HTMLElement>(".acpmux-scroll");
              remote.earlyTop = scroll?.scrollTop ?? 0;
              remote.earlyHeight = scroll?.scrollHeight ?? 0;
              remote.staleAtFirstPaint = !!document.querySelector(".acpmux-peer-copy");
            });
          }
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (remoteTail && state.latest && scroller) {
            remote.finalTop = scroller.scrollTop;
            remote.finalHeight = scroller.scrollHeight;
            remote.maxTopDrift = Math.max(remote.maxTopDrift, Math.abs(remote.finalTop - remote.earlyTop));
            remote.maxHeightDrift = Math.max(remote.maxHeightDrift, Math.abs(remote.finalHeight - remote.earlyHeight));
            if (
              !remote.reconciled &&
              remote.attachReceived &&
              !document.querySelector(".acpmux-peer-copy") &&
              document.body.textContent?.includes(latestText)
            )
              afterPaint(() => (remote.reconciled ||= performance.now()));
          }
          const top = scroller ? scroller.scrollTop + scroller.scrollHeight : -1;
          if (top !== state.top) {
            if (state.latest) state.drift += 1;
            state.top = top;
            state.activity = Math.max(state.activity, now);
          }
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      },
      [
        LATEST,
        process.env.TRACE === "1" ? "trace" : process.env.INSTRUMENT === "1",
        HOST_LATENCY,
        REMOTE_TAIL,
        peerSnapshot(),
      ] as const,
    );
    attachedAt = 0;
    arrivals = new Map();
    calls = [];
    socketOpenedAt = 0;
    const started = Date.now();
    await page.goto(url);
    await page.waitForFunction(
      (remoteTail) => {
        const state = (window as unknown as { __open: { latest: number; activity: number } }).__open;
        const remote = (window as unknown as { __remoteTail: { reconciled: number } }).__remoteTail;
        return (
          state.latest > 0 &&
          (!remoteTail || remote.reconciled > 0) &&
          performance.now() - Math.max(state.latest, state.activity, remote.reconciled) > 400
        );
      },
      REMOTE_TAIL,
      { timeout: 120_000, polling: 100 },
    );
    const got = await page.evaluate(() => {
      const state = (
        window as unknown as {
          __open: {
            firstRow: number;
            latest: number;
            activity: number;
            longTasks: number;
            longMs: number;
            shift: number;
            drift: number;
          };
        }
      ).__open;
      const forced = (window as unknown as { __forced: unknown }).__forced;
      const nav = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming;
      const scripts = performance
        .getEntriesByType("resource")
        .filter(
          (r) => (r as PerformanceResourceTiming).initiatorType === "script" || r.name.endsWith(".js"),
        ) as PerformanceResourceTiming[];
      const loads = (performance.getEntriesByType("resource") as PerformanceResourceTiming[]).map(
        (r) => `${r.responseEnd.toFixed(0)} loaded ${r.name.split("/").pop()} (from ${r.startTime.toFixed(0)})`,
      );
      return {
        ...state,
        remote: (window as unknown as { __remoteTail: Round["remote"] }).__remoteTail,
        trace: [...(window as unknown as { __trace: string[] }).__trace, ...loads].sort(
          (a, b) => Number.parseFloat(a) - Number.parseFloat(b),
        ),
        origin: performance.timeOrigin,
        forced,
        dcl: nav.domContentLoadedEventEnd,
        scriptKiB: scripts.reduce((sum, r) => sum + r.decodedBodySize, 0) / 1024,
        scripts: scripts
          .map((r) => `${r.name.split("/").pop()} ${(r.decodedBodySize / 1024).toFixed(0)} KiB`)
          .sort((a, b) => Number(b.split(" ").at(-2)) - Number(a.split(" ").at(-2))),
      };
    });
    const reveal = REVEAL
      ? await page.evaluate(
          async ({ message, rowId }): Promise<Reveal> => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const result: Reveal = {
              first: 0,
              settled: 0,
              drift: 0,
              driftPx: 0,
              centers: 0,
              scans: 0,
            };
            const intoView = Element.prototype.scrollIntoView;
            const query = Document.prototype.querySelectorAll;
            const elementQuery = Element.prototype.querySelectorAll;
            Element.prototype.scrollIntoView = function (options) {
              result.centers += 1;
              return intoView.call(this, options);
            };
            Document.prototype.querySelectorAll = function (this: Document, selector: string) {
              if (selector === "[data-row-id]") result.scans += 1;
              return query.call(this, selector);
            } as typeof query;
            Element.prototype.querySelectorAll = function (this: Element, selector: string) {
              if (selector === "[data-row-id]") result.scans += 1;
              return elementQuery.call(this, selector);
            } as typeof elementQuery;
            const started = performance.now();
            let top = scroller.scrollTop;
            let firstTop = top;
            let activity = started;
            try {
              window.cmuxAcpmuxBridge!.revealTurn!(`message:${message}`);
              await new Promise<void>((resolve, reject) => {
                const tick = () => {
                  const now = performance.now();
                  const row = document.querySelector<HTMLElement>(`[data-row-id="${rowId}"]`);
                  const box = row?.getBoundingClientRect();
                  const view = scroller.getBoundingClientRect();
                  if (!result.first && box && box.bottom > view.top && box.top < view.bottom) {
                    result.first = now - started;
                    firstTop = scroller.scrollTop;
                    activity = now;
                  }
                  if (scroller.scrollTop !== top) {
                    if (result.first && now - started > result.first) result.drift += 1;
                    top = scroller.scrollTop;
                    activity = now;
                  }
                  if (result.first) result.driftPx = Math.max(result.driftPx, Math.abs(top - firstTop));
                  // A quiet 500 ms includes the old marker's 100 ms poll, rather than stopping at
                  // the virtual layout's first scroll and missing its delayed DOM recenter.
                  if (result.first && now - activity > 500) {
                    result.settled = activity - started;
                    resolve();
                  } else if (now - started > 5000)
                    reject(new Error("message reveal did not become visible and settle"));
                  else requestAnimationFrame(tick);
                };
                requestAnimationFrame(tick);
              });
              return result;
            } finally {
              Element.prototype.scrollIntoView = intoView;
              Document.prototype.querySelectorAll = query;
              Element.prototype.querySelectorAll = elementQuery;
            }
          },
          { message: REVEAL_MESSAGE, rowId: REVEAL_ROW },
        )
      : { first: 0, settled: 0, drift: 0, driftPx: 0, centers: 0, scans: 0 };
    if (REVEAL && process.env.FAST_CHECKS_OUT)
      await page
        .locator(".acpmux-scroll")
        .screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `reveal-${rail}.png`) });
    await page.close();
    const attach = attachedAt ? attachedAt - got.origin : 0;
    if (process.env.TRACE === "1") {
      console.log(
        `trace of one load (ms from navigation): attach answered ${attach.toFixed(0)}, latest ${got.latest.toFixed(0)}`,
      );
      for (const line of got.trace as string[]) console.log(`  ${line}`);
      console.log(
        `  calls (ms after the socket opened at ${(socketOpenedAt - got.origin).toFixed(0)}): ${calls.join(", ")}`,
      );
    }
    const at = (when: number | undefined) => (when ? when - got.origin : 0);
    void started;
    return {
      reveal,
      remote: got.remote,
      attach,
      firstRow: got.firstRow,
      latest: got.latest,
      settled: Math.max(got.latest, got.activity),
      longTasks: got.longTasks,
      longMs: got.longMs,
      shift: got.shift,
      drift: got.drift,
      socket: at(socketOpenedAt),
      initialize: at(arrivals.get("initialize")),
      watch: at(arrivals.get("_acpmux/watch")),
      dcl: got.dcl,
      scriptKiB: got.scriptKiB,
      scripts: got.scripts as unknown as string[],
      forced: got.forced as Round["forced"],
    };
  };

  if (process.env.PROFILE === "1") {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
    await cdp.send("Profiler.start");
    await page.goto(url);
    await page.getByText(LATEST, { exact: false }).first().waitFor({ timeout: 120_000 });
    await page.waitForTimeout(500);
    const { profile } = (await cdp.send("Profiler.stop")) as {
      profile: {
        nodes: {
          id: number;
          callFrame: {
            functionName: string;
            url: string;
            lineNumber: number;
            columnNumber: number;
          };
          children?: number[];
        }[];
        samples: number[];
        timeDeltas: number[];
      };
    };
    const mapper = sourceMapper(out);
    const byId = new Map(profile.nodes.map((node) => [node.id, node]));
    const self = new Map<string, number>();
    profile.samples.forEach((id, index) => {
      const frame = byId.get(id)!.callFrame;
      const file = frame.url.split("/").slice(-1)[0] ?? "";
      const where = file ? mapper(file, frame.lineNumber, frame.columnNumber) : "(native)";
      const key = `${frame.functionName || "(anon)"} ${where}`;
      self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
    });
    // By script (or native, program, garbage collector) and by elapsed window: where the boot goes.
    const byFile = new Map<string, number>();
    const byWindow = new Map<string, number>();
    let clock = 0;
    profile.samples.forEach((id, index) => {
      clock += (profile.timeDeltas[index] ?? 0) / 1000;
      const frame = byId.get(id)!.callFrame;
      const file = frame.url.split("/").slice(-1)[0] || frame.functionName || "(native)";
      byFile.set(file, (byFile.get(file) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
      if (frame.functionName === "(idle)") return;
      const bucket = `${Math.floor(clock / 25) * 25} ms`;
      byWindow.set(bucket, (byWindow.get(bucket) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
    });
    // The busiest functions (self time, with their callers' file) in each 100 ms of the load.
    const perWindow = new Map<number, Map<string, number>>();
    const parents = new Map<number, (typeof profile.nodes)[number]>();
    for (const node of profile.nodes) for (const child of node.children ?? []) parents.set(child, node);
    let at = 0;
    profile.samples.forEach((id, index) => {
      const delta = (profile.timeDeltas[index] ?? 0) / 1000;
      at += delta;
      const node = byId.get(id)!;
      if (node.callFrame.functionName === "(idle)") return;
      // A native frame (layout, style, compile) is named with its nearest JS caller.
      let named = node;
      while (named && !named.callFrame.url) named = parents.get(named.id) ?? (undefined as never);
      const frame = named?.callFrame ?? node.callFrame;
      const key = `${node.callFrame.functionName || "(anon)"}${named && named !== node ? ` <- ${frame.functionName || "(anon)"} ${mapper(frame.url.split("/").pop() ?? "", frame.lineNumber, frame.columnNumber)}` : ` ${mapper(frame.url.split("/").pop() ?? "", frame.lineNumber, frame.columnNumber)}`}`;
      const window = Math.floor(at / 100) * 100;
      const bucket = perWindow.get(window) ?? new Map<string, number>();
      bucket.set(key, (bucket.get(key) ?? 0) + delta);
      perWindow.set(window, bucket);
    });
    for (const [window, bucket] of [...perWindow].sort((a, b) => a[0] - b[0]).slice(0, 8)) {
      const busy = [...bucket.values()].reduce((a, b) => a + b, 0);
      console.log(`window ${window}-${window + 100} ms: busy ${busy.toFixed(0)} ms`);
      for (const [key, ms] of [...bucket].sort((a, b) => b[1] - a[1]).slice(0, 7))
        console.log(
          `  ${ms.toFixed(1)}\t${key.replace(/home\/runner\/_work\/cmux\/cmux\/.fast-checks-checkout\/webviews\//g, "").slice(0, 150)}`,
        );
    }
    console.log("profile by script (ms):");
    for (const [key, ms] of [...byFile].sort((a, b) => b[1] - a[1]).slice(0, 15))
      console.log(`${ms.toFixed(1)}\t${key}`);
    console.log("busy per 25 ms window from profile start (ms):");
    console.log([...byWindow].map(([key, ms]) => `${key}: ${ms.toFixed(0)}`).join(", "));
    const total = [...self.values()].reduce((a, b) => a + b, 0);
    console.log(`profile: ${total.toFixed(0)} ms sampled; top self time (ms)`);
    for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 45)) console.log(`${ms.toFixed(1)}\t${key}`);
    await page.close();
  }
  // ARMS=off,compact: the thread rail's layout per arm (compact is the default), interleaved in
  // alternating order so drift hits every arm alike.
  const arms = process.env.ARMS?.split(",") ?? ["compact"];
  await open(arms[0]); // warm the page's caches
  const byArm = new Map<string, Round[]>(arms.map((arm) => [arm, []]));
  for (let round = 0; round < ROUNDS; round += 1)
    for (const arm of round % 2 ? [...arms].reverse() : arms) byArm.get(arm)!.push(await open(arm));
  for (const [arm, rounds] of byArm) {
    const median = (pick: (r: Round) => number) =>
      rounds.map(pick).sort((a, b) => a - b)[Math.floor(rounds.length / 2)]!;
    console.log(
      `chat-open [rail ${arm}]: ${TURNS} turns, answers delayed ${LATENCY} ms (host ${HOST_LATENCY} ms), ${events.length} events, attach page ${attachEvents} events, ${(attachBytes / 1024).toFixed(0)} KiB, median of ${ROUNDS}`,
    );
    console.log(
      "boot: page DOMContentLoaded ms | socket opened ms | initialize arrived ms | watch arrived ms | script KiB (decoded)",
    );
    console.log(
      [
        median((r) => r.dcl).toFixed(0),
        median((r) => r.socket).toFixed(0),
        median((r) => r.initialize).toFixed(0),
        median((r) => r.watch).toFixed(0),
        median((r) => r.scriptKiB).toFixed(0),
      ].join(" | "),
    );
    if (process.env.INSTRUMENT === "1") {
      const last = rounds.at(-1)!.forced;
      console.log(
        `forced layout in one load: scrollTop writes ${last.writes} (${last.writeMs.toFixed(1)} ms) ${JSON.stringify(last.byClass)}, getBoundingClientRect reads ${last.reads} (${last.readMs.toFixed(1)} ms)`,
      );
      for (const line of last.log) console.log(`  scrollTop write: ${line}`);
    }
    console.log(`scripts loaded (${rounds[0]!.scripts.length}): ${rounds[0]!.scripts.slice(0, 12).join(", ")}`);
    console.log(
      "attach ms | firstRow ms | latest ms | settled ms | long tasks | long ms | layout shift | scroll moves after latest",
    );
    console.log(
      [
        median((r) => r.attach).toFixed(0),
        median((r) => r.firstRow).toFixed(0),
        median((r) => r.latest).toFixed(0),
        median((r) => r.settled).toFixed(0),
        median((r) => r.longTasks).toFixed(0),
        median((r) => r.longMs).toFixed(0),
        median((r) => r.shift).toFixed(4),
        median((r) => r.drift).toFixed(0),
      ].join(" | "),
    );
    if (REMOTE_TAIL) {
      console.log(
        `remote tail ${REMOTE_TAIL}: initialize delayed ${PEER_CONNECT_MS} ms; origins are navigation and native tail request, not a native Mac click`,
      );
      console.log(
        "tail request ms | request to latest paint ms | attach received ms | reconciled paint ms | first paint before attach | stale at first paint | max scrollTop drift px | max scrollHeight drift px | final scrollTop px | final scrollHeight px",
      );
      console.log(
        [
          median((r) => r.remote.tailRequested).toFixed(1),
          median((r) => r.latest - r.remote.tailRequested).toFixed(1),
          median((r) => r.remote.attachReceived).toFixed(1),
          median((r) => r.remote.reconciled).toFixed(1),
          rounds.every((r) => r.latest < r.remote.attachReceived),
          rounds.every((r) => r.remote.staleAtFirstPaint),
          median((r) => r.remote.maxTopDrift).toFixed(1),
          median((r) => r.remote.maxHeightDrift).toFixed(1),
          median((r) => r.remote.finalTop).toFixed(1),
          median((r) => r.remote.finalHeight).toFixed(1),
        ].join(" | "),
      );
      for (const [metric, pick, unit] of [
        ["request_to_paint", (r: Round) => r.latest - r.remote.tailRequested, "ms"],
        ["reconciled", (r: Round) => r.remote.reconciled, "ms"],
        ["scroll_top_drift", (r: Round) => r.remote.maxTopDrift, "px"],
        ["scroll_height_drift", (r: Round) => r.remote.maxHeightDrift, "px"],
      ] as const)
        perfRow({
          name: `chat_open.${arm}.remote_${REMOTE_TAIL}.${metric}`,
          p50: median(pick),
          p95: median(pick),
          unit,
        });
    }
    if (REVEAL) {
      console.log(
        "reveal: first visible ms | settled ms | moves after visible | max drift px | scrollIntoView calls | row scans",
      );
      console.log(
        (["first", "settled", "drift", "driftPx", "centers", "scans"] as const)
          .map((key) => median((r) => r.reveal[key]).toFixed(1))
          .join(" | "),
      );
      for (const [metric, unit] of [
        ["first", "ms"],
        ["settled", "ms"],
        ["drift", "count"],
        ["driftPx", "px"],
        ["centers", "count"],
        ["scans", "count"],
      ] as const)
        perfRow({
          name: `chat_open.${arm}.reveal_${metric.toLowerCase()}`,
          p50: median((r) => r.reveal[metric]),
          p95: median((r) => r.reveal[metric]),
          unit,
        });
    }
    // The median of rounds, as both p50 and p95 (perfRow.ts); stages from navigation start.
    for (const [stage, pick, target] of [
      ["attach", (r: Round) => r.attach, undefined],
      ["first_row", (r: Round) => r.firstRow, undefined],
      ["latest", (r: Round) => r.latest, TARGET_MS.load],
      ["settled", (r: Round) => r.settled, undefined],
      // The page's own work once the history has left the daemon: parse, first render and layout.
      ["attach_to_latest", (r: Round) => r.latest - r.attach, undefined],
      ["dom_content_loaded", (r: Round) => r.dcl, undefined],
      ["long_ms", (r: Round) => r.longMs, undefined],
    ] as const)
      perfRow({ name: `chat_open.${arm}.${stage}`, p50: median(pick), p95: median(pick), target });
  }
} finally {
  await release();
}
