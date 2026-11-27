// l10n-allow-file: test fixture chat names and messages, not shipped UI.
// A fake acpmux daemon for the agent pair tests (agent-pane-agent-pair*.test.tsx): the records
// acpmux's agent pair guard (#21975, cmux-tui/crates/acpmux/src/hub/agent_pairs.rs) writes, a
// socket that answers attach with them, and the requests the page sent.
import { AcpmuxDirectClient } from "../../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";

export const CHAT = "0190a000-0000-7000-8000-0000000000a1";
export const PEER = "0190a000-0000-7000-8000-0000000000b2";
export const OTHER_CHAT = "0190a000-0000-7000-8000-0000000000c3";
export const START = Date.UTC(2026, 9, 19, 9, 0, 0);

export type Step = [dir: string, kind: string, msg: Record<string, unknown>];
export type Record_ = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown };

export const record = (steps: Step[], from = 1): Record_[] =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

export const paused = (fields: Record<string, unknown> = {}): Step => [
  "mux",
  "agent_pair_paused",
  {
    peer: PEER,
    peerName: "Reviewer",
    reason: "alternating",
    count: 10,
    promptId: "p-9",
    windowSecs: 600,
    resume: "_acpmux/agent_pair_resume",
    ...fields,
  },
];
export const held = (promptId: string, text: string): Step => [
  "mux",
  "agent_pair_held",
  {
    from: PEER,
    fromName: "Reviewer",
    to: CHAT,
    promptId,
    text,
    provenance: { kind: "agent_message", from: PEER },
    prompt: [{ type: "text", text }],
    client: "acpmux",
    control: "agent",
    trustGate: false,
  },
];
export const resumed = (delivered: number, by = "request"): Step => [
  "mux",
  "agent_pair_resumed",
  { peer: PEER, by, delivered },
];
export const released = (promptId: string): Step => ["mux", "agent_pair_released", { promptId, peer: PEER }];
export const dropped = (promptId: string): Step => [
  "mux",
  "agent_pair_dropped",
  { promptId, peer: PEER, error: "the chat is gone" },
];

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events;
/// `requests` lists every request the page sent. An attach to `OTHER_CHAT` waits for `openOther`.
export function fakeDaemon(history: Record_[]) {
  let socket: any;
  let openOther = () => {};
  const otherOpened = new Promise<void>((resolve) => (openOther = resolve));
  const requests: { method: string; params: any }[] = [];
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  });
  const answer = async (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(CHAT), session(OTHER_CHAT)] };
      case "_acpmux/attach":
        if (params?.sessionId === OTHER_CHAT) {
          await otherOpened;
          return { session: session(OTHER_CHAT), lastSeq: 0, events: [] };
        }
        return { session: session(CHAT), lastSeq: history.at(-1)?.seq ?? 0, events: history };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      // The X on a waiting steer takes it back (conversation/PendingSteer.tsx).
      case "_acpmux/queue_edit":
        return params?.op === "withdraw" ? { ...params, ok: true } : null;
      case "_acpmux/agent_pair_resume":
        return { sessionId: params.sessionId, resumed: 1, delivered: 2 };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        requests.push({ method: message.method, params: message.params });
        void answer(message.method, message.params).then((result) =>
          socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: Record_[]) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  const resumes = () => requests.filter((request) => request.method === "_acpmux/agent_pair_resume");
  return { open, push, requests, resumes, openOther };
}

export async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}

export const pairRows = (rows: AcpmuxRow[]) => rows.filter((row) => row.kind === "agentPair");
export const pairs = (rows: AcpmuxRow[]) => pairRows(rows).map((row) => row.agentPair!);
