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
