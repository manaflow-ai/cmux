// Manual hosted harness; intentionally outside the CI test registry.
// Run from webviews: CMUX_BROWSER_TESTS=1 CMUX_RECONNECT_CAPTURE_DIR=DIR bun scripts/agent-pane/reconnect-hole.harness.ts
// (hosted: scripts/agent-pane/reconnect-hole.hosted.sh records the base and the fix in one run).
// l10n-allow-file: synthetic transcript and measurement diagnostics.
//
// Leo, 2026-11-17, on a huge chat after its pane's acpmux socket dropped and came back: "THIS KIND
// OF RERENDER RESHIFT RE-MOVING EVERYTHING IS UNACCEPTABLE". The pane attached the newest page,
// then read the hole between the rows it held and that page forward, 5,000 records a read, and
// drew every read above the newest turn (direct.ts `fetchMissedEvents`); a reconnect's forward
// attach (`ForwardAttach`) drew the hole's oldest page, then every read after it, below the rows
// held, the newest turn last. This records the real pane in Chromium through that reconnect and
// prints RECONNECT_HOLE_RECEIPT: the number of distinct row-id lists above the newest prompt across
// painted frames (1 when it holds still), the frames stopped on a stretch of the hole, the reads
// after a seq, and the time from the drop to the open's last answer.
import assert from "node:assert/strict";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium } from "playwright";
import { createServer } from "vite";
import { installPaintedFrames } from "../../test/support/paintedFrames";
import { warmViteServer } from "../../test/support/warmDevServer";

assert.equal(process.env.CMUX_BROWSER_TESTS, "1", "Run on a hosted browser worker only");
const capture = process.env.CMUX_RECONNECT_CAPTURE_DIR;
const label = process.env.CMUX_RECONNECT_LABEL ?? "run";
if (capture) await mkdir(capture, { recursive: true });
const READ_DELAY_MS = Number(process.env.CMUX_RECONNECT_READ_DELAY_MS ?? 250);
const WATCH_MS = Number(process.env.CMUX_RECONNECT_WATCH_MS ?? 18_000);
const INITIAL_TURNS = 2_000;
const AWAY_RECORDS = 60_000;
const ATTACH_PAGE = 80;
const NEWEST = "NEWEST PROMPT: is the transcript above me holding still?";

const sessionId = "0190a000-0000-7000-8000-00000000beef";
const START = 1_794_900_000_000;
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown };
const events: Event[] = [];
const record = (dir: string, kind: string, msg: unknown) => {
  const seq = events.length + 1;
  events.push({ sessionId, seq, at: START + seq * 1000, dir, kind, msg });
  return seq;
};
const chunk = (text: string, messageId: string) => ({
  method: "session/update",
  params: {
    sessionId,
    update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
    _meta: { acpmux: { segment: `${messageId}.1` } },
  },
});
const turn = (question: string, answer: string, id: string) => {
  record("mux", "user_message", { text: question });
  record("mux", "turn_started", {});
  record("in", "agent_message_chunk", chunk(answer, id));
  record("mux", "turn_result", { status: "completed", stopReason: "end_turn" });
};
for (let n = 0; n < INITIAL_TURNS; n++)
  turn(
    `Earlier question ${n}`,
    `Earlier answer ${n}. ${"The morning's work, read before the drop. ".repeat(3)}`,
    `e${n}`,
  );
let status = "idle";
/// While the pane is away the chat runs on: 60,000 records of turns, then a running turn whose
/// streamed reply fills the attach's whole page, so the rows on screen right above the newest
/// prompt are the hole's (base: swapped read by read) or older pages read on scroll (fix).
const PAGE_TURNS = Number(process.env.CMUX_RECONNECT_PAGE_TURNS ?? 0);
const growWhileAway = () => {
  const newestRecords = ATTACH_PAGE - PAGE_TURNS * 4;
  const target = events.length + AWAY_RECORDS;
  for (let n = 0; events.length < target; n++) {
    const seq = events.length + 1;
    turn(
      `Away question ${n} (seq ${seq})`,
      `Away answer ${n}, written while the pane was gone (seq ${seq}). ${"Later work. ".repeat(4)}`,
      `a${n}`,
    );
  }
  record("mux", "user_message", { text: NEWEST });
  record("mux", "turn_started", {});
  for (let n = 0; n < newestRecords - 2; n++) record("in", "agent_message_chunk", chunk(`step ${n} `, "newest"));
  status = "running";
};
const session = () => ({
  sessionId,
  cwd: "/synthetic/project",
  title: "Synthetic huge chat",
  harness: "claude",
  family: "claude",
  status,
  turnCount: events.filter((event) => event.kind === "user_message").length,
  createdAt: START,
  updatedAt: events.at(-1)!.at,
  lastSeq: events.length,
});
type Params = { beforeSeq?: number; afterSeq?: number; limit?: number; promptIndex?: unknown };
/// Pages as acpmux does (server/requests.rs): an attach answers the newest records (at most
/// ATTACH_PAGE), a reconnect's attach with `afterSeq` the oldest after it (unless
/// CMUX_RECONNECT_IGNORE_AFTER_SEQ=1, an older acpmux or a peer); a read before a seq answers the
/// newest before it; a read after a seq answers the oldest after it; each honors `limit` and says
/// `hasMore`.
const IGNORE_AFTER_SEQ = process.env.CMUX_RECONNECT_IGNORE_AFTER_SEQ === "1";
const pageOf = (params: Params, attach: boolean) => {
  const after = attach && IGNORE_AFTER_SEQ ? 0 : Number(params.afterSeq ?? 0);
  const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
  const newest = params.beforeSeq !== undefined || (attach && after === 0);
  let limit = params.limit === undefined ? 5_000 : Math.max(1, Number(params.limit));
  if (attach) limit = Math.min(limit, ATTACH_PAGE);
  const eligible = events.filter((event) => event.seq > after && event.seq < before);
  const out = newest ? eligible.slice(-limit) : eligible.slice(0, limit);
  return { events: out, hasMore: eligible.length > out.length, lastSeq: events.length };
};
const afterReads: { afterSeq: number; limit: number; answered: number; at: number }[] = [];
let attaches = 0;
let connections = 0;
/// When the reconnect's open was last answered: its attach, then every read after a seq it waits on.
let openAnsweredAt = 0;
let droppedAt = 0;
const sockets = new Set<{ send(data: string): void; close(): void }>();
const daemon = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(request, server) {
    return server.upgrade(request, { data: undefined }) ? undefined : new Response("synthetic", { status: 426 });
  },
  websocket: {
    open(ws) {
      connections++;
      sockets.add(ws);
    },
    close(ws) {
      sockets.delete(ws);
    },
    message(ws, raw) {
      const { id, method, params = {} } = JSON.parse(String(raw)) as { id?: number; method: string; params?: Params };
      if (id === undefined) return;
      let result: unknown = null;
      let delay = 0;
      if (method === "initialize")
        result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      else if (method === "_acpmux/watch") result = { sessions: [session()] };
      else if (method === "_acpmux/attach") {
        attaches++;
        const last = events.length;
        result = { session: session(), ...pageOf(params, true), pageThrough: last, turnOpener: null };
      } else if (method === "_acpmux/events") {
        if (params.beforeSeq !== undefined && params.promptIndex)
          result = { events: [], hasMore: false, lastSeq: events.length };
        else {
          const page = pageOf(params, false);
          result = page;
          if (params.beforeSeq === undefined) {
            // A busy remote acpmux: each read forward takes a moment, so a page drawn per read shows.
            delay = READ_DELAY_MS;
            afterReads.push({
              afterSeq: Number(params.afterSeq ?? 0),
              limit: Number(params.limit ?? 0),
              answered: page.events.length,
              at: Date.now(),
            });
          }
        }
      }
      const opening = method === "_acpmux/attach" || (method === "_acpmux/events" && params.beforeSeq === undefined);
      const send = () => {
        if (opening && droppedAt > 0) openAnsweredAt = Date.now();
        try {
          ws.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
        } catch {}
      };
      if (delay > 0) setTimeout(send, delay);
      else send();
    },
  },
});
const vite = await createServer({
  configFile: path.resolve(import.meta.dir, "../../vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1200, height: 860 },
  ...(capture ? { recordVideo: { dir: capture, size: { width: 1200, height: 860 } } } : {}),
});
const page = await context.newPage();
const pageOpenedAt = Date.now();
const errors: string[] = [];
page.on("pageerror", (error) => errors.push(error.message));
type Probe = {
  frames: number;
  framesWithNewest: number;
  stretchFrames: number;
  firstNewestAt?: number;
  t0: number;
  mounted: string[];
  visible: string[];
  visibleSwaps: number;
  mountedSwaps: number;
  changes: { at: number; mounted: number; visible: number; firstVisible?: string; lastVisible?: string }[];
  stop(): void;
};
let receipt: Record<string, unknown> = {};
try {
  await vite.listen();
  await warmViteServer(vite, "/");
  await installPaintedFrames(page);
  const { port } = vite.httpServer!.address() as { port: number };
  await page.goto(
    `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId}`,
  );
  await page.getByText(`Earlier question ${INITIAL_TURNS - 1}`, { exact: true }).waitFor({ timeout: 60_000 });
  for (let n = 0; n < 30; n++) await page.evaluate(() => window.cmuxPaintFrame());
  // Every painted frame: the rows above the newest prompt, mounted and on screen, as id lists.
  await page.evaluate((newest) => {
    const mountedSeen = new Set<string>();
    const visibleSeen = new Set<string>();
    const probe = {
      frames: 0,
      framesWithNewest: 0,
      stretchFrames: 0,
      firstNewestAt: undefined as number | undefined,
      t0: performance.now(),
      mounted: [] as string[],
      visible: [] as string[],
      visibleSwaps: 0,
      mountedSwaps: 0,
      changes: [] as Probe["changes"],
      stop: () => {},
    };
    let lastVisible = "";
    // A swap: the rows nearest the newest prompt changed, neither list a tail of the other. Rows
    // read in above, or scrolled off the top, keep the nearest ones; a page drawn in their place
    // does not.
    const tail = (long: string[], short: string[]) =>
      short.length <= long.length && short.every((id, n) => long[long.length - short.length + n] === id);
    const swapped = (a: string[], b: string[]) => !tail(a, b) && !tail(b, a);
    let prevVisible: string[] | undefined;
    let prevMounted: string[] | undefined;
    probe.stop = window.cmuxAfterPaint(() => {
      probe.frames++;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      if (!scroller) return;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
      const at = rows.findIndex((row) => row.textContent?.includes(newest));
      if (at < 0) {
        // A stretch of the hole drawn without the newest turn under it: a forward read stopped on.
        if (rows.some((row) => row.textContent?.includes("Away question"))) probe.stretchFrames++;
        return;
      }
      if (probe.firstNewestAt === undefined) probe.firstNewestAt = Math.round(performance.now() - probe.t0);
      probe.framesWithNewest++;
      const view = scroller.getBoundingClientRect();
      const above = rows.slice(0, at);
      const mounted = JSON.stringify(above.map((row) => row.dataset.rowId));
      const shown = above.filter((row) => {
        const box = row.getBoundingClientRect();
        return box.height > 0 && box.bottom > view.top && box.top < view.bottom;
      });
      const visible = JSON.stringify(shown.map((row) => row.dataset.rowId));
      const visibleIds = shown.map((row) => row.dataset.rowId!);
      const mountedIds = above.map((row) => row.dataset.rowId!);
      if (prevVisible && swapped(prevVisible, visibleIds)) probe.visibleSwaps++;
      if (prevMounted && swapped(prevMounted, mountedIds)) probe.mountedSwaps++;
      prevVisible = visibleIds;
      prevMounted = mountedIds;
      mountedSeen.add(mounted);
      visibleSeen.add(visible);
      if (visible !== lastVisible) {
        lastVisible = visible;
        probe.changes.push({
          at: Math.round(performance.now() - probe.t0),
          mounted: above.length,
          visible: shown.length,
          firstVisible: shown[0]?.textContent?.slice(0, 60),
          lastVisible: shown.at(-1)?.textContent?.slice(0, 60),
        });
      }
      probe.mounted = [...mountedSeen];
      probe.visible = [...visibleSeen];
    });
    (window as unknown as { reconnectProbe: unknown }).reconnectProbe = probe;
  }, NEWEST);
  growWhileAway();
  // Times in the page from here: the drop.
  await page.evaluate(() => {
    (window as unknown as { reconnectProbe: Probe }).reconnectProbe.t0 = performance.now();
  });
  droppedAt = Date.now();
  for (const ws of sockets) ws.close();
  // Wall time, not frames: the video is the record of what a reader saw.
  await new Promise((resolve) => setTimeout(resolve, WATCH_MS));
  const probe = await page.evaluate(() => {
    const p = (window as unknown as { reconnectProbe: Probe }).reconnectProbe;
    p.stop();
    return { ...p, stop: undefined };
  });
  const finalText = await page.evaluate(() =>
    [...document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].map((row) =>
      (row.textContent ?? "").slice(0, 50),
    ),
  );
  receipt = {
    label,
    distinctAboveNewestVisible: probe.visible.length,
    distinctAboveNewestMounted: probe.mounted.length,
    visibleSwaps: probe.visibleSwaps,
    mountedSwaps: probe.mountedSwaps,
    frames: probe.frames,
    framesWithNewest: probe.framesWithNewest,
    // Frames that stopped on a stretch of the hole with no newest turn under it.
    stretchFrames: probe.stretchFrames,
    // From the drop: the newest turn first painted, and the open's last answer (its attach, then
    // every read after a seq it waits on; "Waiting for the agent service" shows until then).
    newestPaintedMs: probe.firstNewestAt,
    openDoneMs: openAnsweredAt > 0 ? openAnsweredAt - droppedAt : undefined,
    ignoresAfterSeq: IGNORE_AFTER_SEQ,
    afterSeqReads: afterReads.length,
    afterSeqReadsDetail: afterReads.map((read) => ({ ...read, at: read.at - droppedAt })),
    attaches,
    connections,
    totalRecords: events.length,
    readDelayMs: READ_DELAY_MS,
    dropAtVideoMs: droppedAt - pageOpenedAt,
    visibleChanges: probe.changes.slice(0, 60),
    finalMountedRows: finalText.slice(-12),
    errors,
  };
  console.log(`RECONNECT_HOLE_RECEIPT=${JSON.stringify(receipt)}`);
} finally {
  const video = page.video();
  await context.close();
  if (capture && video) await video.saveAs(path.join(capture, `${label}.webm`)).catch(() => undefined);
  await browser.close();
  await vite.close();
  await daemon.stop(true);
}
