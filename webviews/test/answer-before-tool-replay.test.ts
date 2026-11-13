// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// The direct client must shape the same substantive answer before a tool whether the turn is live,
// settled in place, or reconstructed from a cold attach. The table case is Leo's regression shape;
// the one-sentence case makes sure a useful answer is not mistaken for tool narration.
import { afterEach, expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";

const CHAT = "answer-before-tool-replay";
const START = Date.UTC(2026, 10, 13, 0, 50, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (messageId: string, text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } }),
];
const tool = (id: string): Step[] => [
  [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: "Ask the socket-ready lane",
      kind: "execute",
      status: "pending",
    }),
  ],
  ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" })],
];
const record = (steps: Step[]): EventRecord[] =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + (index + 1) * 1000,
    dir,
    kind,
    msg,
  }));

const cases = [
  {
    name: "table",
    answer:
      "Small is slower because startup dominates.\n\n" +
      "| lane | time |\n| --- | ---: |\n| small | 14s |\n| huge | 3s |\n\n" +
      "The larger lane amortizes the setup cost.",
  },
  {
    name: "short",
    answer: "Small is slower because startup dominates.",
  },
] as const;

function eventsFor(answer: string, ended: boolean): EventRecord[] {
  const steps: Step[] = [
    ["mux", "user_message", { text: "Compare the small and huge lanes", promptId: "prompt-1", turnId: "turn-1" }],
    ["mux", "turn_started", { turnId: "turn-1", promptId: "prompt-1" }],
    say("answer-1", answer),
    ...tool("ask-1"),
    say("receipt-1", "I sent the question."),
  ];
  if (ended) steps.push(["mux", "turn_result", { status: "completed", turnId: "turn-1" }]);
  return record(steps);
}

function fakeDaemon(history: EventRecord[]) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "Answer before tool",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const answerFor = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answerFor(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: EventRecord[]) => {
    for (const event of events)
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  return { open, push };
}

async function connected(history: EventRecord[]) {
  const daemon = fakeDaemon(history);
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, daemon, rows: () => rows };
}

function view(rows: AcpmuxRow[], expanded = false) {
  const options = { now: START + 60_000, agentFamily: "claude" };
  const closed = turnViewFrom(rows, new Set(), options);
  const foldIds = new Set(closed.rows.filter((row) => row.kind === "worked").map((row) => row.id));
  return expanded ? turnViewFrom(rows, foldIds, options).rows : closed.rows;
}

function texts(rows: AcpmuxRow[]) {
  return rows
    .filter((row) => row.kind === "assistant")
    .map((row) => row.text)
    .filter(Boolean);
}

afterEach(() => {
  delete globalThis.cmuxExperiments;
});

for (const fixture of cases) {
  test(`${fixture.name}: live, ended and cold reload keep the answer before the tool`, async () => {
    const ended = eventsFor(fixture.answer, true);
    const live = await connected(ended.slice(0, -1));
    expect(texts(view(live.rows()))).toContain(fixture.answer);
    live.daemon.push(ended.slice(-1));
    await new Promise((resolve) => setTimeout(resolve, 0));
    const settled = view(live.rows());
    expect(texts(settled)).toContain(fixture.answer);
    expect(texts(settled)).toContain("I sent the question.");
    expect(settled.flatMap((row) => row.items ?? []).some((item) => item.tool?.id === "ask-1")).toBe(false);
    const expanded = view(live.rows(), true);
    expect(texts(expanded).filter((text) => text === fixture.answer)).toHaveLength(1);
    expect(expanded.flatMap((row) => row.items ?? []).filter((item) => item.tool?.id === "ask-1")).toHaveLength(1);
    live.client.close();

    const cold = await connected(ended);
    const reloaded = view(cold.rows());
    expect(texts(reloaded)).toContain(fixture.answer);
    expect(texts(reloaded)).toContain("I sent the question.");
    expect(reloaded.flatMap((row) => row.items ?? []).some((item) => item.tool?.id === "ask-1")).toBe(false);
    cold.client.close();
  });
}
