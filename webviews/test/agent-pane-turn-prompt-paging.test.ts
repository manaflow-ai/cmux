// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The snapshot names the running turn's prompt (direct.ts `turnPrompt`), and a Stop kept through a
// reconnect goes only to that turn (stopThroughReconnect.ts). Paging older history folds older
// prompts through the same reducer; the running turn must keep its own prompt, or a Stop kept
// after the page reads the wrong turn and is dropped (Codex re-review of #27804, P2).
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e1";
const START = Date.UTC(2026, 9, 30, 3, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const say = (text: string) => ({
  method: "session/update",
  params: { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const ask = (n: number): Step[] => [
  ["mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` }],
  ["mux", "turn_started", { promptId: `p-${n}`, turnId: `t-${n}` }],
];
const turn = (n: number): Step[] => [
  ...ask(n),
  ["in", "agent_message_chunk", say(`Answer ${n} `.repeat(4000))],
  ["mux", "turn_result", { stopReason: "end_turn", status: "completed", turnId: `t-${n}` }],
];
const records = (steps: Step[]): Rec[] =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));

function daemon(history: Rec[]) {
  const lastSeq = history.length;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "running",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 6,
    updatedAt: START,
    lastSeq,
  };
  const page = (beforeSeq: number, limit: number) => {
    const events = history.filter((e) => e.seq < beforeSeq).slice(-limit);
    return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq };
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        // The open page starts at the running turn's prompt: older pages fold above it (direct.ts foldOlder).
        return { session, ...page(lastSeq + 1, 3) };
      case "_acpmux/events": {
        const kinds: unknown = params?.kinds;
        if (Array.isArray(kinds)) {
          const all = history.filter((e) => e.seq < (params?.beforeSeq ?? Infinity) && kinds.includes(e.kind));
          return { events: all.slice(-(params?.limit ?? 5000)), hasMore: false, lastSeq };
        }
        return page(params?.beforeSeq ?? lastSeq + 1, 6);
      }
      default:
        return null;
    }
  };
  let socket: any;
  return () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

test("paging older history keeps the running turn's prompt", async () => {
  // Five finished turns, then turn 6 still running.
  const history = records([
    ...[1, 2, 3, 4, 5].flatMap(turn),
    ...ask(6),
    ["in", "agent_message_chunk", say("Working")] satisfies Step,
  ]);
  type Shown = { isWorking: boolean; turnPrompt?: string; canLoadOlder: boolean };
  let shown: Shown = { isWorking: false, canLoadOlder: false };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => (shown = next),
    undefined,
    daemon(history),
  );
  await settle();
  expect(shown.isWorking).toBe(true);
  expect(shown.turnPrompt).toBe("p-6");
  expect(shown.canLoadOlder).toBe(true);
  for (let asks = 0; shown.canLoadOlder && asks < 10; asks++) {
    await client.loadOlder();
    await settle();
    expect(shown.turnPrompt).toBe("p-6");
  }
  client.close();
});
