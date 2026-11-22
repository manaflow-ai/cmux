// l10n-allow-file: test fixtures, not shipped UI.
// Opening a chat costs the same however long its history is (Leo: "even if a chat is long, there should be no
// percievable difference"). A coordinator chat of 3.7M records and 25,540 background shells held a 4 GB renderer:
// its page read and kept every shell the chat ever ran (66 MB of JSON at the synthetic god-chat shape), so the
// bytes it read on open grew with the history (cmux#44174). This gate opens a chat the way the pane does (attach,
// then the process registry's read while the chat works) at two history lengths past every window the page
// keeps, and holds the bytes read and the processes kept by the longer one to 1.2x the shorter one.
// Detector for the class "a chat page's open cost grows with history length" (cmuxterm-hq
// docs/handbook/perf-regresses-on-degenerate-sessions.md, "Chat open cost at the god-chat shape").
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { PROCESS_LIST_RECENT, type SessionInfoProcess } from "../src/agent-session/acpmux/session-info/processes";

const CHAT = "0190a000-0000-7000-8000-0000000000e6";
const START = Date.UTC(2026, 10, 16, 1, 0, 0);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/// Record `seq` (1-based) of a chat of four-record turns: a question, its start, an answer, its end.
function recordAt(seq: number) {
  const turn = Math.floor((seq - 1) / 4);
  const at = START + turn * 3_000;
  const base = { sessionId: CHAT, seq, at };
  switch ((seq - 1) % 4) {
    case 0:
      return { ...base, dir: "mux", kind: "user_message", msg: { text: `Question ${turn}` } };
    case 1:
      return { ...base, dir: "mux", kind: "turn_started", msg: {} };
    case 2:
      return {
        ...base,
        dir: "in",
        kind: "agent_message_chunk",
        msg: {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Answer ${turn}: green.` } },
          },
        },
      };
    default:
      return { ...base, dir: "mux", kind: "turn_result", msg: { status: "completed" } };
  }
}

/// Process `n` of a chat that ran `count`; one in `runningEvery` still runs, as a long chat's dev servers do.
const processAt = (n: number, runningEvery: number) => ({
  id: `${CHAT}/task-${n}`,
  sessionId: CHAT,
  toolCallId: `call-${n}`,
  command: `bun test test/case-${n}.test.ts && cargo test -p acpmux case_${n} -- --nocapture`,
  description: `Run case ${n}`,
  state: n % runningEvery === 7 ? "running" : "exited",
  exitCode: n % runningEvery === 7 ? undefined : 0,
  startedAt: START + n * 1_000,
  endedAt: n % runningEvery === 7 ? undefined : START + n * 1_000 + 500,
});

/// A stand-in acpmux for one chat of `records` records and `processes` background processes, answering as acpmux
/// does: attach and `_acpmux/events` by page, `_acpmux/process/list` by `recent` or by `limit` and `cursor`.
/// `received` counts the bytes the page read.
function daemon(records: number, processes: number) {
  const stats = { received: 0 };
  const runningEvery = 1_700;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "Coordinator",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: Math.floor(records / 4),
    updatedAt: START,
    lastSeq: records,
  };
  const page = (before: number, limit: number) => {
    const from = Math.max(1, before - limit);
    const events: unknown[] = [];
    for (let seq = from; seq < before; seq += 1) events.push(recordAt(seq));
    return { events, hasMore: from > 1 };
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: records, ...page(records + 1, Number(params?.limit ?? 400)) };
      case "_acpmux/events":
        if (params?.beforeSeq === undefined || params?.promptIndex === true)
          return { events: [], hasMore: false, lastSeq: records };
        return { ...page(Number(params.beforeSeq), Number(params.limit ?? 400)), lastSeq: records };
      case "_acpmux/process/list": {
        if (params?.recent !== undefined) {
          const kept: ReturnType<typeof processAt>[] = [];
          let ended = 0;
          for (let n = processes - 1; n >= 0; n -= 1) {
            const process = processAt(n, runningEvery);
            if (process.state !== "running") {
              if (ended >= params.recent) continue;
              ended += 1;
            }
            kept.push(process);
          }
          kept.reverse();
          return { processes: kept, recent: params.recent, omitted: processes - kept.length };
        }
        const from = params?.cursor === undefined ? 0 : Number(String(params.cursor).split("task-")[1]) + 1;
        const rows: ReturnType<typeof processAt>[] = [];
        for (let n = from; n < Math.min(processes, from + Number(params?.limit ?? 1_000)); n += 1)
          rows.push(processAt(n, runningEvery));
        const more = from + rows.length < processes;
        return { processes: rows, nextCursor: more ? rows.at(-1)!.id : null };
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
        queueMicrotask(() => {
          const data = JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            result: answer(message.method, message.params),
          });
          stats.received += data.length;
          socket.onmessage?.({ data });
        });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open, stats };
}

/// What opening the chat costs the page: the bytes it read (attach, then the registry's process read while the chat
/// works) and the processes the registry keeps.
async function openChat(records: number, processes: number) {
  const fake = daemon(records, processes);
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => {},
    undefined,
    fake.open,
  );
  for (let n = 0; n < 20; n += 1) await tick();
  const reply = await client.listProcesses(CHAT, PROCESS_LIST_RECENT);
  const kept = (reply.processes ?? []) as SessionInfoProcess[];
  for (let n = 0; n < 5; n += 1) await tick();
  client.dispose();
  return { bytes: fake.stats.received, kept: kept.length };
}

// Both lengths are past every window the page keeps (attach's page, the registry's newest ended processes), so a
// page whose cost is constant in history length reads the same at both. The longer one is the real god chat's shape.
test("opening a 3.7M-record chat with 56,000 shells costs what a 40,000-record chat with 2,000 does (<= 1.2x)", async () => {
  const shorter = await openChat(40_000, 2_000);
  const god = await openChat(3_700_000, 56_426);
  expect(god.bytes).toBeLessThanOrEqual(shorter.bytes * 1.2);
  expect(god.kept).toBeLessThanOrEqual(shorter.kept * 1.2);
  // And in absolute terms: one attach page and one window of processes, never a history.
  expect(god.bytes).toBeLessThan(2_000_000);
});
