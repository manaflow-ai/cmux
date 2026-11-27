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
//   first_contentful_paint  the browser's first-contentful-paint entry: the web app's first paint of anything
//              (Leo, 2026-11-22: "we also need startup times of the app to keep hill climbing"). Its row's p50 is
//              the rounds' median and its p95 their nearest-rank 95th percentile; each round also prints the HTML's
//              responseEnd and DOMContentLoaded beside it, so the cost before the first paint splits into fetch and
//              script.
// The stages that follow `attach` are the page's own: parse, first render and layout passes.
// Long tasks (count, total) and the layout-shift sum cover the whole load; the transcript's scroll drift
// after `latest` says how much the page still moved after the newest messages appeared.
//   [LATENCY=ms] [HOST_LATENCY=ms] bun bench/chat-open.bench.ts [rounds=7] [turns=300]
// REMOTE_TAIL=present|absent uses a cold remote chat, with PEER_CONNECT_MS=2000 delaying
// initialize independently of ordinary RPC latency. The native host snapshot is available before
// that handshake. Measures navigation and tail-request origins separately; neither is a Mac click.
// REVEAL=1 also opens an offscreen message after the chat settles, then records scroll drift
// from its first visible frame, delayed scrollIntoView calls and transcript-wide row scans.
// FIXTURE=god opens the god session (bench/godFixture.ts: tens of thousands of rows, MB tool outputs, nested
// subagents, images, months of history) instead of the TURNS-turn chat, and names every row chat_open.god.*: a row
// pairs with its ordinary twin by dropping `.god` (chat_open.god.compact.latest, chat_open.compact.latest).
// PAIRED=1 (with FIXTURE=god) opens the TURNS-turn chat and the god session in the same rounds, interleaved, so both
// chats' rows (chat_open.* and chat_open.god.*) and their god_ratio come from one runner in one job.
// Every run also loads a fixed calibration page in each round (bench/runnerCalibration.ts): its median is
// chat_open.calibration_ms (chat_open.god.calibration_ms when FIXTURE=god), and each chat's
// chat_open.<rail>.attach_to_latest_per_calibration is the median of each round's attach_to_latest over that round's
// calibration, unit x: the page's own work in units of the runner's speed, which holds where the raw ms tracks the
// runner. The raw ms rows stay as they were. With PAIRED=1 each chat also has chat_open_paired[.god].<rail>.*: the
// same rounds' attach_to_latest (ms) and its median over each load's own DOMContentLoaded (attach_per_dcl, unit x).
// COMPOSER=1 (goal startup-every-path; Leo 2026-11-22: "percieved time and percieved interactive time") also types one
// letter into the chat's composer as soon as its field is in the document and editable, and marks, from navigation start:
//   composer_ready        the field is first in the document and editable (a MutationObserver from the first byte);
//   composer_interactive  the frame after the letter echoed in the field (its text holds it), so the key was accepted.
// The letter lands mid-load, so layout shifts in the 500 ms after it are the browser's hadRecentInput ones and leave the
// shift sum: the web-ui part runs without it. Its rows (and dom_content_loaded and first_row) also carry `samples`, each
// round's value, which cmuxterm-hq's web-startup probe reads for its p50 and p95.
// PROFILE=1 adds a CPU profile of one load and prints the functions with the most self time between
// navigation and the newest message plus 500 ms. The build is then unminified (so functions keep their
// names) and every timed round runs on it, so the stage times are not the production build's. It also prints
// the stretch from the attach's answer to the newest message: busy and idle ms, a task timeline (React phase or
// outermost page function), the idle stretches, the time by React phase and component, self time by file, and the
// functions by self and total time.
// TRACE=1 logs the page's socket and fetches, the transcript rows mounted and unmounted per DOM mutation batch
// (about one per commit) and the frames.
// PANE_OUT=dir builds the pane into dir once and reuses it on later runs (bench/chat-open-ab.sh).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { newestPage } from "./daemonPage";
import { benchFixture, godChat, LATEST_TEXT, type Scale, scaledPerfRow } from "./godFixture";
import { type PerfRow, perfRow as printRow, TARGET_MS } from "./perfRow";
import {
  CALIBRATION_HTML,
  CALIBRATION_VERSION,
  median as medianOf,
  perCalibration,
  roundOrder,
} from "./runnerCalibration";
import { sourceMapper } from "./sourceMapper";
import { sharedPaneDir } from "./support/sharedBuilds";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
const FIXTURE = benchFixture();
const PAIRED = process.env.PAIRED === "1";
if (PAIRED && FIXTURE !== "god")
  throw new Error("PAIRED=1 opens the small chat beside the god one; run it with FIXTURE=god");
const CALIBRATION_PATH = "/__calibration.html";
/// The stage rows marked with nextFrame (in the page script below), whose measure changed in version 3.
const NEXT_FRAME_STAGES: ReadonlySet<string> = new Set(["first_row", "latest", "attach_to_latest"]);
/// COMPOSER=1: the stage rows that carry each round's value (`samples`), for the web-startup probe's p50 and p95.
const SAMPLED_STAGES: ReadonlySet<string> = new Set([
  "dom_content_loaded",
  "first_row",
  "composer_ready",
  "composer_interactive",
]);
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
const COMPOSER = process.env.COMPOSER === "1";
/// The chat's composer field (composer-typing.bench.ts's PROMPT).
const COMPOSER_FIELD =
  ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
/// The letter COMPOSER=1 types; the field's text must hold it.
const COMPOSER_KEY = "q";
if (REVEAL && FIXTURE === "god")
  throw new Error("REVEAL=1 reveals a row of the TURNS-turn chat; run it without FIXTURE=god");
if (PAIRED && REMOTE_TAIL) throw new Error("PAIRED=1 measures local chats; run REMOTE_TAIL without it");
const REVEAL_MESSAGE = "bench-reveal";
const REVEAL_TURN = Math.max(1, TURNS - 40);
const REVEAL_ROW = `assistant-${(REVEAL_TURN - 1) * 4 + 3}`;
const webviews = path.resolve(import.meta.dir, "..");

const remoteFields = REMOTE_TAIL ? { peer: "bench-vm", createdAt: 100 } : {};
/// A chat the stand-in can serve: its events, its newest message's text, its rows' printer, and its last attach page.
type Fixture = ReturnType<typeof godChat> | ReturnType<typeof papercutEvents>;
type Chat = {
  scale: Scale;
  events: Fixture["events"];
  session: Fixture["session"];
  latest: string;
  perfRow: (row: PerfRow) => void;
  attachBytes: number;
  attachEvents: number;
};
const chatAt = (scale: Scale): Chat => {
  const { events, session } =
    scale === "god"
      ? godChat(PAPERCUT_CHAT, remoteFields)
      : papercutEvents({ turns: TURNS, running: false, session: remoteFields });
  const latest = scale === "god" ? LATEST_TEXT : `Answer ${TURNS}:`;
  return { scale, events, session, latest, perfRow: scaledPerfRow(printRow, scale), attachBytes: 0, attachEvents: 0 };
};
/// The chats this run opens: FIXTURE's, or with PAIRED=1 the small chat and the god one. The stand-in serves `current`,
/// one load at a time, so both share its port and the page's URL.
const chats = ((PAIRED ? ["small", "god"] : [FIXTURE]) as Scale[]).map(chatAt);
let current = chats.at(-1)!;
let { events, session, latest: LATEST } = current;
const use = (chat: Chat) => {
  current = chat;
  ({ events, session, latest: LATEST } = chat);
};
if (REVEAL) {
  const event = events.find((event) => event.seq === (REVEAL_TURN - 1) * 4 + 3)!;
  const update = (event.msg.params as { update: Record<string, unknown> }).update;
  update.messageId = REVEAL_MESSAGE;
}
let attachedAt = 0;
/// When each protocol call first reached the stand-in in this load (epoch ms).
let arrivals = new Map<string, number>();
let socketOpenedAt = 0;
/// Every call of this load, with when it came (ms after the socket opened), for TRACE=1.
let calls: string[] = [];
/// The newest page before `beforeSeq`, oldest first, and whether older ones remain: the page the daemon
/// answers an attach or an older-history read with, cut by count and by `maxBytes` (daemonPage.ts).
const newest = (limit: number, beforeSeq = Infinity, maxBytes?: unknown) =>
  newestPage(events, { limit, beforeSeq, maxBytes });
const peerSnapshot = () => ({
  sessionId: PAPERCUT_CHAT,
  qualifiedSessionId: `bench-vm/${PAPERCUT_CHAT}`,
  peer: "bench-vm",
  generation: 100,
  capturedAt: Date.UTC(2026, 10, 3),
  stale: true,
  summary: session,
  events: REMOTE_TAIL === "present" ? newest(400).page : [],
  hasMore: REMOTE_TAIL === "present" && newest(400).hasMore,
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
      // As the daemon does: the newest `limit` events within `maxBytes`, and hasMore while older ones remain.
      const { page, hasMore } = newest(Number(params.limit ?? 400), Infinity, params.maxBytes);
      const result = { session, lastSeq: events.at(-1)?.seq ?? 0, events: page, hasMore };
      current.attachBytes = JSON.stringify(result).length;
      current.attachEvents = page.length;
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
        const { page, hasMore } = newest(Number(params.limit ?? 400), Number(params.beforeSeq), params.maxBytes);
        return { events: page, hasMore, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      return { events: [], hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    }
    default:
      return null;
  }
};

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

  // PANE_OUT=dir keeps the pane's build there and takes one already in it, so a harness that runs the
  // bench many times on one checkout (bench/chat-open-ab.sh) builds each side once.
  // Under bench/web-ui-suite.ts, the suite's one pane build of the run (bench/support/sharedBuilds.ts).
  const variant = process.env.PROFILE === "1";
  const keptOut = process.env.PANE_OUT ? path.resolve(process.env.PANE_OUT) : sharedPaneDir({ variant });
  const out = keptOut ?? fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-open-bench-"));
  if (!keptOut) releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const { build } = await import("vite");
  if (!keptOut || !fs.existsSync(path.join(out, "index.html")))
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: {
        outDir: out,
        emptyOutDir: true,
        ...(variant ? { minify: false, sourcemap: true } : {}),
      },
      logLevel: "error",
    });
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      if (pathname === CALIBRATION_PATH)
        return new Response(CALIBRATION_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
      const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({
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
    fcp: number;
    responseEnd: number;
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
    composerReady: number;
    composerInteractive: number;
  };
  const open = async (rail = "compact"): Promise<Round> => {
    const page = await browser.newPage({
      viewport: { width: 1200, height: 800 },
      deviceScaleFactor: REVEAL ? 2 : 1,
    });
    await page.addInitScript((rail) => {
      localStorage.setItem("cmux.experiments", JSON.stringify({ "thread-minimap-layout": rail }));
    }, rail);
    if (COMPOSER)
      await page.addInitScript(
        ([field, key]) => {
          const marks = { ready: 0, interactive: 0 };
          (window as unknown as { __composer: typeof marks }).__composer = marks;
          const check = () => {
            const editable = document.querySelector(field);
            if (!marks.ready && editable) marks.ready = performance.now();
            if (!marks.interactive && editable?.textContent?.includes(key))
              requestAnimationFrame(() => (marks.interactive ||= performance.now()));
          };
          new MutationObserver(check).observe(document, {
            subtree: true,
            childList: true,
            characterData: true,
            attributes: true,
            attributeFilter: ["contenteditable"],
          });
        },
        [COMPOSER_FIELD, COMPOSER_KEY] as const,
      );
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
          // Transcript rows mounted and unmounted, per DOM mutation batch (about one per commit), and the
          // frames: which rows each commit built, and whether a frame painted between them.
          const rowsIn = (nodes: NodeList) => {
            let count = 0;
            for (const node of nodes)
              if (node instanceof Element)
                count += (node.matches("[data-row-id]") ? 1 : 0) + node.querySelectorAll("[data-row-id]").length;
            return count;
          };
          new MutationObserver((records) => {
            let added = 0;
            let removed = 0;
            for (const record of records) {
              added += rowsIn(record.addedNodes);
              removed += rowsIn(record.removedNodes);
            }
            if (added || removed) trace.push(`${performance.now().toFixed(1)} rows +${added} -${removed}`);
          }).observe(document, { childList: true, subtree: true });
          let frames = 0;
          const frame = () => {
            if (frames++ < 120) {
              trace.push(`${performance.now().toFixed(1)} frame`);
              requestAnimationFrame(frame);
            }
          };
          requestAnimationFrame(frame);
          // Each React commit (a devtools hook, as React DOM looks for one at load): how many components
          // rendered, the busiest by count, and every state hook whose value changed, by component: what
          // asked for the commit. Only the commits that mount or update transcript rows' parents matter here,
          // so the first 40 commits are logged.
          type Fiber = {
            tag: number;
            type: unknown;
            flags: number;
            alternate: Fiber | null;
            child: Fiber | null;
            sibling: Fiber | null;
            memoizedState: unknown;
          };
          type Hook = { memoizedState: unknown; queue: unknown; next: Hook | null };
          const nameOf = (fiber: Fiber): string => {
            let type = fiber.type as { displayName?: string; name?: string; type?: unknown; render?: unknown } | null;
            if (type && typeof type === "object" && "type" in type) type = type.type as typeof type;
            if (type && typeof type === "object" && "render" in type) type = type.render as typeof type;
            return (type && (type.displayName || type.name)) || "?";
          };
          let commits = 0;
          (window as unknown as { __REACT_DEVTOOLS_GLOBAL_HOOK__: unknown }).__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
            isDisabled: false,
            supportsFiber: true,
            renderers: new Map(),
            inject: () => 1,
            onScheduleFiberRoot: () => {},
            onCommitFiberUnmount: () => {},
            onPostCommitFiberRoot: () => {},
            onCommitFiberRoot: (_id: number, root: { current: Fiber }) => {
              if (commits++ >= 40) return;
              const rendered = new Map<string, number>();
              const changed: string[] = [];
              const walk = (fiber: Fiber | null) => {
                for (let at = fiber; at; at = at.sibling) {
                  const component = at.tag === 0 || at.tag === 1 || at.tag === 11 || at.tag === 14 || at.tag === 15;
                  // PerformedWork (1): this fiber rendered in this commit.
                  if (component && (at.flags & 1 || !at.alternate)) {
                    const name = nameOf(at);
                    rendered.set(name, (rendered.get(name) ?? 0) + 1);
                    if (at.alternate && at.tag !== 1) {
                      let hook = at.memoizedState as Hook | null;
                      let was = at.alternate.memoizedState as Hook | null;
                      let index = 0;
                      while (hook && was) {
                        if (
                          hook.queue &&
                          hook.memoizedState !== was.memoizedState &&
                          typeof hook.memoizedState !== "function"
                        )
                          changed.push(
                            /^(TranscriptView|ThreadMinimapView|ThreadMinimap)$/.test(name)
                              ? `${name}#${index}=${String(JSON.stringify(was.memoizedState) ?? was.memoizedState).slice(0, 40)}->${String(JSON.stringify(hook.memoizedState) ?? hook.memoizedState).slice(0, 40)}`
                              : `${name}#${index}`,
                          );
                        hook = hook.next;
                        was = was.next;
                        index += 1;
                      }
                    }
                  }
                  // A subtree React skipped keeps the fibers (and flags) of the commit that last rendered it:
                  // its children are the same objects as the alternate's, so it is not walked.
                  if (!at.alternate || at.child !== at.alternate.child) walk(at.child);
                }
              };
              walk(root.current.child);
              let total = 0;
              for (const count of rendered.values()) total += count;
              const busiest = [...rendered]
                .sort((a, b) => b[1] - a[1])
                .slice(0, 6)
                .map(([n, c]) => `${n}x${c}`);
              trace.push(
                `${performance.now().toFixed(1)} commit ${commits}: ${total} rendered (${busiest.join(" ")}); state changed: ${
                  [
                    ...changed.reduce(
                      (counts, key) => counts.set(key, (counts.get(key) ?? 0) + 1),
                      new Map<string, number>(),
                    ),
                  ]
                    .map(([key, count]) => (count > 1 ? `${key}x${count}` : key))
                    .slice(0, 24)
                    .join(" ") || "-"
                }`,
              );
            },
          };
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
        // The first row and the newest message are marked when the next frame starts, which is after the frame that
        // drew them painted. afterPaint's setTimeout queued behind whatever task the page ran next: on the god chat
        // that is the ~120 ms render of 64 rows once the highlighter's chunks load, so about half the loads marked
        // the newest message after it (attach_to_latest 250 ms against 127 ms, the same frame painted at the same time;
        // TRACE=1 shows both). The page's work after the paint still counts in settled, long_ms and long tasks.
        const nextFrame = (done: () => void) => requestAnimationFrame(() => done());
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
            nextFrame(() => (state.firstRow ||= performance.now()));
          if (!state.latest && document.body.textContent?.includes(latestText)) {
            // TRACE=1: how much the first frame with the newest message drew.
            if (instrument === "trace") {
              const count = (selector: string) => document.querySelectorAll(selector).length;
              trace.push(
                `${now.toFixed(0)} drawn: ${count("[data-row-id]")} rows, ${count(".acpmux-minimap__entry")} rail entries, ${count("*")} elements, ${count(".acpmux-composer *, .acpmux-header *")} in composer and header`,
              );
            }
            nextFrame(() => {
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
    // COMPOSER=1: the letter goes in as soon as the field exists, while the page still loads.
    const typed = COMPOSER
      ? page.goto(url, { waitUntil: "commit" }).then(async () => {
          const field = await page.waitForSelector(COMPOSER_FIELD, { timeout: 120_000 });
          await field.focus();
          await page.keyboard.type(COMPOSER_KEY);
          await page.waitForFunction(
            () => (window as unknown as { __composer: { interactive: number } }).__composer.interactive > 0,
            null,
            { timeout: 60_000 },
          );
        })
      : page.goto(url);
    await typed;
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
        fcp: performance.getEntriesByName("first-contentful-paint")[0]?.startTime ?? 0,
        responseEnd: nav.responseEnd,
        composer: (window as unknown as { __composer?: { ready: number; interactive: number } }).__composer ?? {
          ready: 0,
          interactive: 0,
        },
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
              // The page's bridge (App.tsx declares it on Window); this file doesn't import App.
              (window as unknown as { cmuxAcpmuxBridge: { revealTurn(id: string): void } }).cmuxAcpmuxBridge.revealTurn(
                `message:${message}`,
              );
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
      fcp: got.fcp,
      responseEnd: got.responseEnd,
      scriptKiB: got.scriptKiB,
      scripts: got.scripts as unknown as string[],
      forced: got.forced as Round["forced"],
      composerReady: got.composer.ready,
      composerInteractive: got.composer.interactive,
    };
  };

  if (process.env.PROFILE === "1") {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
    // When the newest message was first in the page (epoch ms), so the profile can be cut to the stretch
    // between the attach's answer and it: the page's own parse, replay and first render.
    await page.addInitScript((latestText) => {
      const tick = () => {
        if (document.body?.textContent?.includes(latestText))
          (window as unknown as { __latestAt: number }).__latestAt = performance.timeOrigin + performance.now();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, LATEST);
    attachedAt = 0;
    await cdp.send("Profiler.start");
    const profileStart = Date.now();
    await page.goto(url);
    await page.getByText(LATEST, { exact: false }).first().waitFor({ timeout: 120_000 });
    await page.waitForTimeout(500);
    const latestAt = await page.evaluate(() => (window as unknown as { __latestAt?: number }).__latestAt ?? 0);
    const profileAttach = attachedAt;
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
    if (process.env.RAWPROF) fs.writeFileSync(process.env.RAWPROF, JSON.stringify(profile));
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
    // From the attach's answer to the newest message in the page: what the page spent, by function (self
    // and with its callees), and how long it sat idle (a timer, a frame or an await between the two).
    if (profileAttach && latestAt) {
      const from = profileAttach - profileStart;
      const to = latestAt - profileStart;
      const windowSelf = new Map<string, number>();
      const windowTotal = new Map<string, number>();
      let idle = 0;
      let busy = 0;
      let clockAt = 0;
      // Each idle stretch of 2 ms or more, as start+length from the attach: where the page waited.
      const gaps: string[] = [];
      let gapFrom = -1;
      const runs: { task: string; at: number; ms: number; parts: Map<string, number> }[] = [];
      const byOuter = new Map<string, number>();
      const byFileSelf = new Map<string, number>();
      profile.samples.forEach((id, index) => {
        const delta = (profile.timeDeltas[index] ?? 0) / 1000;
        clockAt += delta;
        if (clockAt < from || clockAt > to) return;
        const node = byId.get(id)!;
        const name = (frame: (typeof node)["callFrame"]) =>
          `${frame.functionName || "(anon)"} ${frame.url ? mapper(frame.url.split("/").pop() ?? "", frame.lineNumber, frame.columnNumber) : "(native)"}`.replace(
            /home\/runner\/_work\/cmux\/cmux\/.fast-checks-checkout\/webviews\//g,
            "",
          );
        if (node.callFrame.functionName === "(idle)") {
          idle += delta;
          if (gapFrom < 0) gapFrom = clockAt - delta;
          return;
        }
        if (gapFrom >= 0 && clockAt - delta - gapFrom >= 2)
          gaps.push(`${(gapFrom - from).toFixed(0)}+${(clockAt - delta - gapFrom).toFixed(0)}`);
        gapFrom = -1;
        busy += delta;
        // The task timeline: each sample's React phase (render, commit, passive effects) or, outside
        // React, its outermost page function, merged into runs; and per phase, the time under each
        // outermost page function (in a render, the component rendering; in a commit, the effect).
        let outer = "";
        let phase = "";
        for (let up: typeof node | undefined = node; up; up = parents.get(up.id)) {
          const fn = up.callFrame.functionName;
          if (!phase && (fn === "renderRootSync" || fn === "renderRootConcurrent")) phase = "render";
          else if (!phase && fn === "commitRoot") phase = "commit";
          else if (!phase && fn === "flushPassiveEffects") phase = "passive effects";
          const named = name(up.callFrame);
          if (named.includes(" src/")) outer = named;
        }
        const task = phase ? `React ${phase}` : outer || name(node.callFrame);
        const last = runs.at(-1);
        const under = `${phase || "other"}: ${outer || name(node.callFrame)}`;
        let run = last;
        if (last && last.task === task && clockAt - delta - (last.at + last.ms) < 1) last.ms = clockAt - last.at;
        else runs.push((run = { task, at: clockAt - delta, ms: delta, parts: new Map() }));
        const part = phase === "render" ? outer || name(node.callFrame) : name(node.callFrame);
        run!.parts.set(part, (run!.parts.get(part) ?? 0) + delta);
        byOuter.set(under, (byOuter.get(under) ?? 0) + delta);
        const file = name(node.callFrame).split(" ").pop()!.replace(/:\d+$/, "");
        byFileSelf.set(file, (byFileSelf.get(file) ?? 0) + delta);
        windowSelf.set(name(node.callFrame), (windowSelf.get(name(node.callFrame)) ?? 0) + delta);
        const seen = new Set<string>();
        for (let up: typeof node | undefined = node; up; up = parents.get(up.id)) {
          const key = name(up.callFrame);
          if (seen.has(key)) continue;
          seen.add(key);
          windowTotal.set(key, (windowTotal.get(key) ?? 0) + delta);
        }
      });
      console.log(
        `attach to latest in the profiled load: attach answered at ${from.toFixed(0)} ms, latest in the page at ${to.toFixed(0)} ms (${(to - from).toFixed(0)} ms): busy ${busy.toFixed(0)} ms, idle ${idle.toFixed(0)} ms`,
      );
      console.log("  task timeline (ms after the attach, ms, React phase or outermost page function):");
      for (const run of runs.filter((each) => each.ms >= 1)) {
        console.log(`  ${(run.at - from).toFixed(1)}\t${run.ms.toFixed(1)}\t${run.task.slice(0, 140)}`);
        // A long run's largest parts (in a render, the component; otherwise the function with the self time).
        if (run.ms >= 5)
          for (const [part, ms] of [...run.parts].sort((a, b) => b[1] - a[1]).slice(0, 4))
            if (ms >= 1) console.log(`  \t\t  ${ms.toFixed(1)}\t${part.slice(0, 130)}`);
      }
      console.log(`  idle stretches (ms after the attach + ms): ${gaps.join(", ")}`);
      console.log("  by phase and outermost page function (in a render, the component) (ms):");
      for (const [key, ms] of [...byOuter].sort((a, b) => b[1] - a[1]).slice(0, 40))
        console.log(`  ${ms.toFixed(1)}\t${key.slice(0, 160)}`);
      console.log("  self time by file (ms):");
      for (const [key, ms] of [...byFileSelf].sort((a, b) => b[1] - a[1]).slice(0, 25))
        console.log(`  ${ms.toFixed(1)}\t${key.slice(0, 160)}`);
      console.log("  top self time (ms):");
      for (const [key, ms] of [...windowSelf].sort((a, b) => b[1] - a[1]).slice(0, 30))
        console.log(`  ${ms.toFixed(1)}\t${key.slice(0, 160)}`);
      console.log("  top total time, with callees (ms):");
      for (const [key, ms] of [...windowTotal].sort((a, b) => b[1] - a[1]).slice(0, 60))
        console.log(`  ${ms.toFixed(1)}\t${key.slice(0, 160)}`);
    }
    const total = [...self.values()].reduce((a, b) => a + b, 0);
    console.log(`profile: ${total.toFixed(0)} ms sampled; top self time (ms)`);
    for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 45)) console.log(`${ms.toFixed(1)}\t${key}`);
    await page.close();
  }
  // The fixed calibration page (bench/runnerCalibration.ts), cold as each chat load is: ms from navigation start to
  // the paint after its workload.
  const calibrate = async (): Promise<number> => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    await page.goto(`http://127.0.0.1:${statics.port}${CALIBRATION_PATH}`);
    await page.waitForFunction(
      () => ((window as unknown as { __calibrated?: number }).__calibrated ?? 0) > 0,
      undefined,
      {
        timeout: 60_000,
        polling: "raf",
      },
    );
    const ms = await page.evaluate(() => (window as unknown as { __calibrated: number }).__calibrated);
    await page.close();
    return ms;
  };
  // ARMS=off,compact: the thread rail's layout per arm (compact is the default). Every chat's arms and the
  // calibration load run in each round, rotated per round (roundOrder) so drift hits every load alike.
  const arms = process.env.ARMS?.split(",") ?? ["compact"];
  type Load = { chat: Chat; arm: string } | "calibration";
  const loads: Load[] = [...chats.flatMap((chat) => arms.map((arm) => ({ chat, arm }))), "calibration"];
  const key = (chat: Chat, arm: string) => `${chat.scale}:${arm}`;
  // Warm the page's caches, once per chat.
  for (const chat of chats) {
    use(chat);
    await open(arms[0]);
  }
  await calibrate();
  const byArm = new Map<string, Round[]>(
    loads.flatMap((load) => (load === "calibration" ? [] : [[key(load.chat, load.arm), []]])),
  );
  const calibrations: number[] = [];
  for (let round = 0; round < ROUNDS; round += 1)
    for (const load of roundOrder(loads, round)) {
      if (load === "calibration") {
        calibrations.push(await calibrate());
        continue;
      }
      use(load.chat);
      byArm.get(key(load.chat, load.arm))!.push(await open(load.arm));
    }
  const calibrationMs = medianOf(calibrations);
  console.log(
    `calibration page (runnerCalibration.ts v${CALIBRATION_VERSION}): median ${calibrationMs.toFixed(1)} ms of ${calibrations.length}: ${calibrations.map((ms) => ms.toFixed(0)).join(" ")}`,
  );
  // The calibration under FIXTURE's prefix (chat_open.god.calibration_ms with FIXTURE=god), so the perf cron's part that
  // runs this bench keeps it.
  chats.at(-1)!.perfRow({
    name: "chat_open.calibration_ms",
    p50: calibrationMs,
    p95: calibrationMs,
    version: CALIBRATION_VERSION,
  });
  for (const chat of chats)
    for (const arm of arms) {
      use(chat);
      const { perfRow } = chat;
      const rounds = byArm.get(key(chat, arm))!;
      const median = (pick: (r: Round) => number) =>
        rounds.map(pick).sort((a, b) => a - b)[Math.floor(rounds.length / 2)]!;
      console.log(
        `chat-open [rail ${arm}]: ${chat.scale === "god" ? "the god session" : `${TURNS} turns`}, answers delayed ${LATENCY} ms (host ${HOST_LATENCY} ms), ${events.length} events, attach page ${chat.attachEvents} events, ${(chat.attachBytes / 1024).toFixed(0)} KiB, median of ${ROUNDS}`,
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
        ...(COMPOSER
          ? ([
              ["composer_ready", (r: Round) => r.composerReady, undefined],
              ["composer_interactive", (r: Round) => r.composerInteractive, TARGET_MS.load],
            ] as const)
          : []),
      ] as const)
        // Version 2: the pane's build loads English plus the page's language, as the app does
        // (scripts/agent-pane/paneLocales.mjs), no longer all 21 locales before the socket opens.
        // Version 3 (first_row, latest, attach_to_latest): marked when the next frame starts (nextFrame), not after a
        // task that could queue behind the page's next long task.
        perfRow({
          name: `chat_open.${arm}.${stage}`,
          p50: median(pick),
          p95: median(pick),
          target,
          version: NEXT_FRAME_STAGES.has(stage) ? 3 : 2,
          ...(COMPOSER && SAMPLED_STAGES.has(stage) ? { samples: rounds.map(pick) } : {}),
        });
      // The web app's first paint from navigation start, a real p95 across rounds (the stage rows above give one median).
      const fcps = rounds.map((r) => r.fcp).sort((a, b) => a - b);
      console.log(
        `first paint per round (ms from navigation): fcp ${rounds.map((r) => r.fcp.toFixed(0)).join(" ")}; html responseEnd ${rounds.map((r) => r.responseEnd.toFixed(0)).join(" ")}; DOMContentLoaded ${rounds.map((r) => r.dcl.toFixed(0)).join(" ")}`,
      );
      if (fcps.every((fcp) => fcp > 0))
        perfRow({
          name: `chat_open.${arm}.first_contentful_paint`,
          p50: median((r) => r.fcp),
          p95: fcps[Math.max(0, Math.ceil(fcps.length * 0.95) - 1)]!,
          target: TARGET_MS.load,
        });
      else console.log(`chat-open [rail ${arm}]: a round had no first-contentful-paint entry; no first paint row`);
      // The page's own work in units of this runner's speed: each round's attach_to_latest over that round's calibration
      // (runnerCalibration.ts), the median of them. It holds across runners where the ms row above tracks the runner.
      console.log(
        `per round: attach_to_latest ms ${rounds.map((r) => (r.latest - r.attach).toFixed(0)).join(" ")}; attach ms ${rounds.map((r) => r.attach.toFixed(0)).join(" ")}; first row ms ${rounds.map((r) => r.firstRow.toFixed(0)).join(" ")}; long tasks ${rounds.map((r) => r.longTasks).join(" ")}; long ms ${rounds.map((r) => r.longMs.toFixed(0)).join(" ")}`,
      );
      // Every round's value at full precision, for a harness that pools rounds (bench/chat-open-ab.sh).
      console.log(`per round attach_to_latest ms: ${rounds.map((r) => (r.latest - r.attach).toFixed(1)).join(" ")}`);
      console.log(`per round dom_content_loaded ms: ${rounds.map((r) => r.dcl.toFixed(1)).join(" ")}`);
      const perRunner = perCalibration(
        rounds.map((r) => r.latest - r.attach),
        calibrations,
      );
      if (Number.isFinite(perRunner))
        perfRow({
          name: `chat_open.${arm}.attach_to_latest_per_calibration`,
          p50: perRunner,
          p95: perRunner,
          unit: "x",
          version: CALIBRATION_VERSION,
        });
      // PAIRED=1: the rows NOW's chat_attach_p95_ms reads (cmuxterm-hq goal chat-attach-p95, re-plan 2026-11-17).
      // chat_open_paired[.god].<rail>.attach_per_dcl is the median of each round's attach_to_latest over that same
      // load's own DOMContentLoaded, unit x: the same code read 100 to 185 ms across runners while this ratio held at
      // 6.2 to 6.35. attach_to_latest beside it is the same rounds' median ms, the value shown against the ms target.
      // Their own prefix keeps the small chat's paired rows apart from the web-ui part's unpaired chat_open.compact.*.
      if (PAIRED) {
        const perDcl = perCalibration(
          rounds.map((r) => r.latest - r.attach),
          rounds.map((r) => r.dcl),
        );
        console.log(
          `paired ${chat.scale}: attach_to_latest / DOMContentLoaded per round ${rounds.map((r) => ((r.latest - r.attach) / r.dcl).toFixed(2)).join(" ")}; median ${perDcl}`,
        );
        perfRow({
          name: `chat_open_paired.${arm}.attach_to_latest`,
          p50: median((r) => r.latest - r.attach),
          p95: median((r) => r.latest - r.attach),
          version: 3,
        });
        if (Number.isFinite(perDcl))
          perfRow({ name: `chat_open_paired.${arm}.attach_per_dcl`, p50: perDcl, p95: perDcl, unit: "x", version: 1 });
      }
      // The script the page downloaded and parsed by the time the chat settled (decoded KiB): the open's
      // cost that grows with every eager import, so the perf cron names the week it grows (it grew 29%,
      // 8302 to 10722 KiB, from 2026-11-02 to 11-09 with no row to say so).
      const scriptKiB = Math.round(median((r) => r.scriptKiB));
      perfRow({ name: `chat_open.${arm}.script_kib`, p50: scriptKiB, p95: scriptKiB, unit: "KiB", clock: "cpu" });
    }
} finally {
  await release();
}
