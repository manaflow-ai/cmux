// Scratch: per-record cost of live `_acpmux/event` records into a client that holds N rows (N from the attach page).
// Usage: bun /tmp/dsa-bench/stream-at-scale.ts ROWS LIVE
/// <reference types="bun" />
const ROOT = process.env.WEBVIEWS!;
const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
const { OrderedRows } = await import("../src/agent-session/acpmux/direct/orderedRows");
const stats:any={del:0,delHit:0,after:0,live:false,kinds:{} as Record<string,number>};
const od=OrderedRows.prototype.delete; const os=OrderedRows.prototype.sorted; stats.sortedMs=0; stats.sortedCalls=0; stats.sliceMs=0;
(OrderedRows.prototype as any).sorted=function(){ const t=performance.now(); const fresh=!(this as any).snapshot; const r=os.call(this); if(stats.live){stats.sortedMs+=performance.now()-t; if(fresh){stats.sortedCalls++; const t2=performance.now(); r.slice(); stats.sliceMs+=performance.now()-t2;}} return r; };
(OrderedRows.prototype as any).delete=function(id:string){ if(stats.live){stats.del++; if(this.has(id)){stats.delHit++; const r=this.get(id); stats.kinds[r.kind+":"+id.slice(0,12)]=(stats.kinds[r.kind+":"+id.slice(0,12)]??0)+1; const oi=(this as any).orderedIndex?.get(id); const o=(this as any).ordered; if(o&&oi!==undefined) stats.after+=o.length-oi; else stats.kinds["noslot"]=(stats.kinds["noslot"]??0)+1;}} return od.call(this,id); };

const ROWS = Number(process.argv[2] ?? 2000);
const LIVE = Number(process.argv[3] ?? 2000);
const CHAT = "0190a000-0000-7000-8000-00000000f1e7";
const START = Date.UTC(2026, 10, 1, 9, 0, 0);
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const history: Rec[] = [];
const push = (dir: string, kind: string, msg: Record<string, unknown>) =>
  history.push({ sessionId: CHAT, seq: history.length + 1, at: START + history.length * 50, dir, kind, msg });
let turn = 0;
// short turns: question + answer rows; ROWS/2 turns
while (turn * 2 < ROWS) {
  turn++;
  push("mux", "user_message", { text: `Question ${turn}`, promptId: `p-${turn}` });
  push("mux", "turn_started", {});
  push("in", "agent_message_chunk", { method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${turn}.` } } } });
  push("mux", "turn_result", { stopReason: "end_turn" });
}
const lastSeq = history.length;
const session = { sessionId: CHAT, cwd: "/x", title: "t", harness: "claude", family: "claude", status: "ready", turnCount: turn, updatedAt: START + lastSeq * 50, lastSeq };
let socket: any;
const answer = (method: string, params: any) => {
  if (method === "initialize") return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
  if (method === "_acpmux/watch") return { sessions: [session] };
  if (method === "_acpmux/attach") return { session, events: history, hasMore: false, lastSeq };
  if (method === "_acpmux/events") return { events: [], hasMore: false, lastSeq };
  return null;
};
const open = () => {
  socket = {
    readyState: 1,
    send(raw: string) {
      const m = JSON.parse(raw);
      if (m.id === undefined) return;
      const reply = JSON.stringify({ jsonrpc: "2.0", id: m.id, result: answer(m.method, m.params) });
      setTimeout(() => socket.onmessage?.({ data: reply }), 0);
    },
    close() {},
  };
  setTimeout(() => socket.onopen?.(), 0);
  return socket as WebSocket;
};
let snapshot: any = { rows: [] };
let publishes = 0;
const settle = () => new Promise((r) => setTimeout(r, 0));
await AcpmuxDirectClient.connect(
  { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
  (next: any) => { snapshot = next; publishes++; },
  undefined,
  open,
);
for (let i = 0; i < 3000 && (snapshot.rows?.length ?? 0) < Math.min(ROWS, 10); i++) await settle();
for (let i = 0; i < 50; i++) await settle();
const held = snapshot.rows?.length ?? 0;
// a live turn: prompt, start, LIVE chunks, end; each chunk a frame (settle between, as rAF would)
let seq = lastSeq;
const ev = (kind: string, msg: any, dir = "in") => JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: { sessionId: CHAT, seq: ++seq, at: START + seq * 50, dir, kind, msg } });
socket.onmessage({ data: ev("user_message", { text: "live q", promptId: "p-live" }, "mux") });
socket.onmessage({ data: ev("turn_started", {}, "mux") });
await settle();
const times: number[] = []; stats.live=true; const sorts0=OrderedRows.sorts;
const t0 = performance.now();
for (let i = 0; i < LIVE; i++) {
  const s = performance.now();
  socket.onmessage({ data: ev("agent_message_chunk", { method: "session/update", params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `tok${i} ` } } } }) });
  await settle();
  times.push(performance.now() - s);
}
const total = performance.now() - t0;
times.sort((a, b) => a - b);
const p = (q: number) => times[Math.min(times.length - 1, Math.floor(q * times.length))]!;
console.log(JSON.stringify({ rows: ROWS, held, live: LIVE, publishes, total_ms: +total.toFixed(1), per_chunk_p50_ms: +p(0.5).toFixed(3), p95_ms: +p(0.95).toFixed(3) }));
console.log(JSON.stringify({sorts:OrderedRows.sorts-sorts0, ...stats}));
process.exit(0);
