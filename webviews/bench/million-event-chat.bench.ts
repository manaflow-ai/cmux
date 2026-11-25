// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// A 1,000,000-event chat (CMUX-571; Leo on cmux#37713: "we need to be able to work with a 1 million event chat. why
// can't we? is there some inherent limitation? ... it's not like you're reading 1 million events on each turn").
// The pane's chat client (src/agent-session/acpmux/direct.ts, AcpmuxDirectClient) joins a stand-in acpmux that holds
// EVENTS records and pages them as acpmux does (hub/paging.rs: the newest `limit` records before `beforeSeq`, cut at
// `maxBytes`; the prompt index in one reply). SHAPE=long (default): TURNS turns of EVENTS/TURNS records each, a
// stream of message chunks and tool calls, the turns #37713 stopped replaying whole; SHAPE=short: 4-record turns.
// It measures, in this one process:
//   open        connect to the newest answer in the client's snapshot (ms);
//   older page  one `loadOlder` (the transcript's ask at the top) until its rows are in the snapshot, PAGES times
//               from the newest page back (ms, p50 and p95);
//   heap        the JS heap the client holds after the open and after the pages, over the heap before it (MB,
//               after a full collection; the fixture's own records are held before and so are not counted).
// It reads only the client, not React's render of its rows. Prints PERF_ROW lines (million_event_chat.*).
//   bun bench/million-event-chat.bench.ts [events=1000000] [pages=20]
// MODE=window instead scrolls a chat of N pages from its bottom to its top and back (`windowBench` below).
/// <reference types="bun" />
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { perfRow } from "./perfRow";

const EVENTS = Number(process.argv[2] ?? 1_000_000);
const PAGES = Number(process.argv[3] ?? 20);
const SHAPE = process.env.SHAPE === "short" ? "short" : "long";
const PER_TURN = SHAPE === "short" ? 4 : Number(process.env.PER_TURN ?? 1000);
const CHAT = "0190a000-0000-7000-8000-00000000f1e7";
const START = Date.UTC(2026, 10, 1, 9, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const update = (u: Record<string, unknown>) => ({ method: "session/update", params: { update: u } });

/// The chat's records, seq = index + 1.
function fixture(): { history: Rec[]; turns: number } {
  const history: Rec[] = [];
  const push = (dir: string, kind: string, msg: Record<string, unknown>) =>
    history.push({ sessionId: CHAT, seq: history.length + 1, at: START + history.length * 50, dir, kind, msg });
  let turn = 0;
  while (history.length + PER_TURN <= EVENTS) {
    turn++;
    push("mux", "user_message", { text: `Question ${turn}`, promptId: `p-${turn}` });
    push("mux", "turn_started", {});
    for (let i = 0; i < PER_TURN - 3; i++) {
      if (SHAPE === "long" && i % 10 === 9) {
        const id = `t${turn}-${i}`;
        push(
          "in",
          "tool_call",
          update({
            sessionUpdate: "tool_call",
            toolCallId: id,
            title: `rg step ${i}`,
            kind: "search",
            status: "completed",
            rawInput: { pattern: `step ${i}` },
          }),
        );
      } else {
        push(
          "in",
          "agent_message_chunk",
          update({
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: i === PER_TURN - 4 ? `Answer ${turn}: done. ` : `token ${i} ` },
          }),
        );
      }
    }
    push("mux", "turn_result", { stopReason: "end_turn" });
  }
  return { history, turns: turn };
}

const recordBytes = (e: Rec) => JSON.stringify(e.msg).length + e.kind.length + 120;
/// hub/paging.rs events_page: the newest records before `beforeSeq` (oldest first), at most `limit`, ending before
/// their bytes pass `maxBytes`, always at least one. Reads back from `beforeSeq` only, as the daemon's index does.
/// hub/paging.rs page_bytes: 1 MiB when the caller names none, at most 4 MiB.
const pageBytes = (asked: number | undefined) => Math.min(asked ?? 1 << 20, 4 << 20);
function newestPage(history: Rec[], beforeSeq: number, limit: number, asked: number | undefined) {
  const maxBytes = pageBytes(asked);
  const events: Rec[] = [];
  let bytes = 0;
  let index = Math.min(history.length, beforeSeq - 1) - 1;
  for (; index >= 0; index--) {
    if (events.length === limit) break;
    bytes += recordBytes(history[index]!);
    if (events.length > 0 && bytes > maxBytes) break;
    events.push(history[index]!);
  }
  return { events: events.reverse(), hasMore: index >= 0, lastSeq: history.length };
}

function daemon(history: Rec[], turns: number) {
  const lastSeq = history.length;
  const prompts = history.filter((e) => e.kind === "user_message");
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "a million events",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: turns,
    updatedAt: START + lastSeq * 50,
    lastSeq,
  };
  let olderReads = 0;
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, ...newestPage(history, lastSeq + 1, params?.limit ?? 2000, params?.maxBytes) };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        if (params?.promptIndex === true)
          return {
            events: prompts.filter((e) => e.seq < before).map((e) => ({ ...e, msg: { text: e.msg.text } })),
            hasMore: false,
            lastSeq,
          };
        const kinds: unknown = params?.kinds;
        if (Array.isArray(kinds) && !kinds.includes("transcript")) {
          const limit = params?.limit ?? 5000;
          const out: Rec[] = [];
          for (let i = Math.min(history.length, before - 1) - 1; i >= 0 && out.length < limit; i--)
            if (kinds.includes(history[i]!.kind)) out.push(history[i]!);
          return { events: out.reverse(), hasMore: false, lastSeq };
        }
        olderReads++;
        return newestPage(history, params?.beforeSeq ?? lastSeq + 1, params?.limit ?? 5000, params?.maxBytes);
      }
      default:
        return null;
    }
  };
  const open = () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        const reply = JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: answer(message.method, message.params),
        });
        setTimeout(() => socket.onmessage?.({ data: reply }), 0);
      },
      close() {},
    };
    setTimeout(() => socket.onopen?.(), 0);
    return socket as WebSocket;
  };
  return { open, olderReads: () => olderReads };
}

const turnOf = (rows: any[]) => {
  let oldest = Infinity;
  for (const row of rows) {
    const m = /^Question (\d+)/.exec(String(row?.text ?? ""));
    if (m) oldest = Math.min(oldest, Number(m[1]));
  }
  return oldest;
};
const heapMB = () => {
  Bun.gc(true);
  return process.memoryUsage().heapUsed / 1048576;
};
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
const pct = (values: number[], share: number) =>
  values.length === 0
    ? Number.NaN
    : [...values].sort((a, b) => a - b)[Math.min(values.length - 1, Math.floor(share * values.length))]!;

// MODE=window: a reader scrolls from the bottom to the top of a chat of N older pages and back (direct.ts
// `shedNewerHeld`, `loadNewer`). Each N is a fresh client on a stand-in that makes its records as they are asked
// for (seq-numbered, WINDOW_PAGE records a page, one turn a page), so the fixture holds nothing. The reader's view
// is the held rows' top while going up (each older page lands above it) and their end while going down. At each N:
//   heap        the JS heap at the top over the heap before the open (MB, after a full collection);
//   held        records the client holds at the top, and rows it hands the transcript (one height entry each);
//   up / down   one page's cost going up (`loadOlder`) and down (`loadNewer`), ms p50/p95;
//   ratio       each to N=10's.
// The transcript mounts only the rows in view (VirtualTranscript), so the DOM is not this harness's: rows is what
// its layout holds. A side that runs past WINDOW_BUDGET_S (default 900) at an N stops there and says so.
//   MODE=window bun bench/million-event-chat.bench.ts [_] [_] (WINDOW_NS=10,100,1000,10000 WINDOW_PAGE=200)
async function windowBench(): Promise<never> {
  const NS = (process.env.WINDOW_NS ?? "10,100,1000,10000").split(",").map(Number);
  const PAGE = Number(process.env.WINDOW_PAGE ?? 200);
  const BUDGET_MS = Number(process.env.WINDOW_BUDGET_S ?? 900) * 1000;
  const recordAt = (seq: number): Rec => {
    const at = START + seq * 50;
    const phase = (seq - 1) % PAGE;
    if (phase === 0)
      return { sessionId: CHAT, seq, at, dir: "mux", kind: "user_message", msg: { text: `Question ${seq}` } };
    if (phase === 1) return { sessionId: CHAT, seq, at, dir: "mux", kind: "turn_started", msg: {} };
    if (phase === PAGE - 1)
      return { sessionId: CHAT, seq, at, dir: "mux", kind: "turn_result", msg: { stopReason: "end_turn" } };
    if (phase % 10 === 9)
      return {
        sessionId: CHAT,
        seq,
        at,
        dir: "in",
        kind: "tool_call",
        msg: update({
          sessionUpdate: "tool_call",
          toolCallId: `t${seq}`,
          title: `rg step ${seq}`,
          kind: "search",
          status: "completed",
        }),
      };
    return {
      sessionId: CHAT,
      seq,
      at,
      dir: "in",
      kind: "agent_message_chunk",
      msg: update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `token ${seq} ` } }),
    };
  };
  const span = (from: number, to: number, last: number) => {
    const out: Rec[] = [];
    for (let seq = Math.max(1, from); seq <= Math.min(last, to); seq += 1) out.push(recordAt(seq));
    return out;
  };
  const standIn = (lastSeq: number) => {
    const session = {
      sessionId: CHAT,
      cwd: "/home/dev/x",
      title: "a long chat",
      harness: "claude",
      family: "claude",
      status: "ready",
      turnCount: Math.ceil(lastSeq / PAGE),
      updatedAt: START + lastSeq * 50,
      lastSeq,
    };
    const answer = (method: string, params: any) => {
      switch (method) {
        case "initialize":
          return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
        case "_acpmux/watch":
          return { sessions: [session] };
        case "_acpmux/attach":
          return { session, events: span(lastSeq - PAGE + 1, lastSeq, lastSeq), hasMore: true, lastSeq };
        case "_acpmux/events": {
          const limit = Math.min(Number(params?.limit ?? PAGE), PAGE);
          if (params?.promptIndex === true) {
            const events: Rec[] = [];
            for (let seq = 1; seq < Math.min(lastSeq + 1, params?.beforeSeq ?? Infinity); seq += PAGE) {
              const prompt = recordAt(seq);
              events.push({ ...prompt, msg: { text: prompt.msg.text } });
            }
            return { events, hasMore: false, lastSeq };
          }
          const kinds: unknown = params?.kinds;
          if (Array.isArray(kinds) && !kinds.includes("transcript")) {
            // The few-record reads (a turn's opener): the newest user_message before `beforeSeq`.
            const before = Math.min(lastSeq + 1, params?.beforeSeq ?? Infinity);
            const seq = Math.floor((before - 2) / PAGE) * PAGE + 1;
            return { events: seq >= 1 ? [recordAt(seq)] : [], hasMore: false, lastSeq };
          }
          if (params?.beforeSeq !== undefined) {
            const events = span(params.beforeSeq - limit, params.beforeSeq - 1, lastSeq);
            return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq };
          }
          const after = Number(params?.afterSeq ?? 0);
          const events = span(after + 1, after + limit, lastSeq);
          return { events, hasMore: (events.at(-1)?.seq ?? lastSeq) < lastSeq, lastSeq };
        }
        default:
          return null;
      }
    };
    return () => {
      const socket: any = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id === undefined) return;
          const reply = JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            result: answer(message.method, message.params),
          });
          setTimeout(() => socket.onmessage?.({ data: reply }), 0);
        },
        close() {},
      };
      setTimeout(() => socket.onopen?.(), 0);
      return socket as WebSocket;
    };
  };
  type Side = {
    n: number;
    up: number[];
    down: number[];
    heapMB: number;
    held: number;
    rows: number;
    mostHeld: number;
    done: boolean;
    endHeld: number;
  };
  const results: Side[] = [];
  for (const n of NS) {
    const lastSeq = (n + 2) * PAGE;
    const base = heapMB();
    let shown: any = { rows: [] };
    const client: any = await AcpmuxDirectClient.connect(
      { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
      (next: any) => (shown = next),
      undefined,
      standIn(lastSeq),
    );
    for (let i = 0; i < 2000 && (client.events?.length ?? 0) === 0; i++) await settle();
    for (let i = 0; i < 40; i++) await settle();
    client.setFollowing(false);
    client.readerView = () => (shown.rows ?? []).slice(0, 4).map((row: any) => row.id);
    const started = performance.now();
    const up: number[] = [];
    let mostHeld = 0;
    let done = true;
    for (let page = 0; page < n; page++) {
      if (performance.now() - started > BUDGET_MS) {
        done = false;
        break;
      }
      const from = client.events[0]?.seq ?? 0;
      const start = performance.now();
      await client.loadOlder(undefined, false, true);
      await settle();
      up.push(performance.now() - start);
      mostHeld = Math.max(mostHeld, client.events.length);
      if ((client.events[0]?.seq ?? 0) >= from && !shown.canLoadOlder) break;
    }
    for (let i = 0; i < 10; i++) await settle();
    const heapTop = heapMB() - base;
    const heldTop = client.events.length;
    const rowsTop = shown.rows?.length ?? 0;
    client.readerView = () => (shown.rows ?? []).slice(-4).map((row: any) => row.id);
    const down: number[] = [];
    const downStarted = performance.now();
    for (let page = 0; page < 2 * n + 10 && typeof client.loadNewer === "function" && client.hasNewerLeft?.(); page++) {
      if (performance.now() - downStarted > BUDGET_MS) {
        done = false;
        break;
      }
      const start = performance.now();
      await client.loadNewer();
      await settle();
      down.push(performance.now() - start);
      mostHeld = Math.max(mostHeld, client.events.length);
    }
    const endHeld = client.events.length;
    client.close();
    results.push({ n, up, down, heapMB: Math.max(0, heapTop), held: heldTop, rows: rowsTop, mostHeld, done, endHeld });
    console.log(
      `window n=${n}: ${up.length} pages up${done ? "" : " (budget ran out)"}, heap +${heapTop.toFixed(1)} MB at the top, ` +
        `${heldTop} records and ${rowsTop} rows held there (most ${mostHeld}), up p50 ${pct(up, 0.5).toFixed(2)} ms ` +
        `p95 ${pct(up, 0.95).toFixed(2)} ms, ${down.length} pages down p50 ${pct(down, 0.5).toFixed(2)} ms, ` +
        `${endHeld} records held back at the end`,
    );
  }
  const first = results[0]!;
  const ratio = (value: number, of: number) => (of > 0 ? (value / of).toFixed(2) : "-");
  console.log(
    "\n| N pages | pages up | JS heap MB | held records | most held | rows (height entries) | up ms/page p50 | down ms/page p50 | heap / N=10 | held / N=10 | up / N=10 |",
  );
  console.log("|---|---|---|---|---|---|---|---|---|---|---|");
  for (const side of results) {
    const upP50 = pct(side.up, 0.5);
    console.log(
      `| ${side.n} | ${side.up.length}${side.done ? "" : " (budget)"} | ${side.heapMB.toFixed(1)} | ${side.held} | ${side.mostHeld} | ${side.rows} | ` +
        `${upP50.toFixed(2)} | ${side.down.length ? pct(side.down, 0.5).toFixed(2) : "-"} | ${ratio(side.heapMB, first.heapMB)} | ` +
        `${ratio(side.held, first.held)} | ${ratio(upP50, pct(first.up, 0.5))} |`,
    );
    perfRow({
      name: `million_event_chat.window.n${side.n}.held_records`,
      p50: side.held,
      p95: side.mostHeld,
      unit: "records",
    });
    perfRow({ name: `million_event_chat.window.n${side.n}.heap_mb`, p50: side.heapMB, p95: side.heapMB, unit: "MB" });
    if (side.up.length)
      perfRow({
        name: `million_event_chat.window.n${side.n}.up_page`,
        p50: upP50,
        p95: pct(side.up, 0.95),
        unit: "ms",
      });
  }
  process.exit(0);
}
if (process.env.MODE === "window") await windowBench();

const { history, turns } = fixture();
const fake = daemon(history, turns);
const base = heapMB();
let snapshot: any = { rows: [], canLoadOlder: false };
let latestAt = 0;
const latest = `Answer ${turns}:`;
const t0 = performance.now();
const client = await AcpmuxDirectClient.connect(
  { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
  (next: any) => {
    snapshot = next;
    if (!latestAt && JSON.stringify(next.rows?.slice(-3) ?? []).includes(latest)) latestAt = performance.now();
  },
  undefined,
  fake.open,
);
for (let i = 0; i < 2000 && !latestAt; i++) await settle();
const openMs = (latestAt || performance.now()) - t0;
for (let i = 0; i < 20; i++) await settle();
const openHeap = heapMB() - base;
const pages: number[] = [];
let moved = 0;
for (let page = 0; page < PAGES && snapshot.canLoadOlder; page++) {
  const from = snapshot.historyFrom ?? Infinity;
  const start = performance.now();
  await client.loadOlder();
  for (let i = 0; i < 200 && (snapshot.historyFrom ?? Infinity) >= from && snapshot.canLoadOlder; i++) await settle();
  pages.push(performance.now() - start);
  if ((snapshot.historyFrom ?? Infinity) < from) moved++;
}
const pagesHeap = heapMB() - base;
client.close();
console.log(
  `million-event-chat: ${history.length} events, ${turns} turns (${SHAPE}, ${PER_TURN} a turn); open ${openMs.toFixed(0)} ms` +
    `${latestAt ? "" : " (newest answer never shown)"}; older page p50 ${pct(pages, 0.5).toFixed(0)} ms, p95 ` +
    `${pct(pages, 0.95).toFixed(0)} ms (n=${pages.length}, ${moved} moved history, ${fake.olderReads()} reads, oldest ` +
    `turn held ${turnOf(snapshot.rows)}); heap +${openHeap.toFixed(1)} MB after the open, +${pagesHeap.toFixed(1)} MB after ` +
    `the pages; ${snapshot.rows?.length ?? 0} rows`,
);
// A row only for what was measured: no open row when the newest answer never showed, no page row with no page.
// The heap is over a baseline after a full collection, so it can read a little under 0: clamped.
if (latestAt) perfRow({ name: `million_event_chat.${SHAPE}.open`, p50: openMs, p95: openMs, unit: "ms" });
if (pages.length > 0)
  perfRow({ name: `million_event_chat.${SHAPE}.older_page`, p50: pct(pages, 0.5), p95: pct(pages, 0.95), unit: "ms" });
const heapRow = Math.max(0, pagesHeap);
perfRow({ name: `million_event_chat.${SHAPE}.heap_mb`, p50: heapRow, p95: heapRow, unit: "MB" });
process.exit(latestAt && moved > 0 ? 0 : 1);
