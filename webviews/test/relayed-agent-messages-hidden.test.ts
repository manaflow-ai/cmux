// l10n-allow-file: test fixture prompts, replies and messages, not shipped UI.
// The chat draws no message relayed between agents: another agent's message, a lane's message the
// lane-gh broker relayed, and acpmux's inbox notice of such messages all draw nothing, live or
// reloaded, in the transcript or while they wait in the queue. The person's own prompt, the agent's
// replies and a tool's notice still draw.
//
// Leo, 2026-11-12: "STOP FUCKING SHOWING THESE FUCKING MESSAGES", then, quoting "messages relayed
// between agents are showing up in it,": "STOP".
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { type AcpmuxRow, type AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { relayedBetweenAgents } from "../src/agent-session/acpmux/conversation/incomingMessage";
import { queuedMessageRows } from "../src/agent-session/acpmux/conversation/queuedMessages";
import { isVisiblyEmptyMessage } from "../src/agent-session/acpmux/conversation/visibleMessage";

const CHAT = "0190a000-0000-7000-8000-0000000000d1";
const START = Date.UTC(2026, 10, 12, 2, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const record = (steps: Step[]) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + (index + 1) * 1000,
    dir,
    kind,
    msg,
  }));
const say = (messageId: string, text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } }),
];
const turn = (id: string, prompt: Step, reply: string): Step[] => [
  prompt,
  ["mux", "turn_started", { turnId: id, promptId: String(prompt[2].promptId) }],
  say(`m-${id}`, reply),
  ["mux", "turn_result", { status: "completed", turnId: id }],
];

const PERSON = "Watch the release and tell me when it ships";
const AGENT = "release-watch: the nightly is green at 4910f9a0.";
const LANE = "the cloud run is green";
const personPrompt: Step = ["mux", "user_message", { text: PERSON, promptId: "p-1", turnId: "t-1" }];
const agentMessage: Step = [
  "mux",
  "user_message",
  {
    _meta: {
      provenance: {
        from: "fromAgent",
        fromHarness: "codex",
        fromName: "release-watch",
        fromSessionId: "0190a000-0000-7000-8000-00000000bb01",
        kind: "agent_message",
        to: CHAT,
      },
    },
    client: "acpmux-peer#0190a0",
    promptId: "p-2",
    text: AGENT,
    turnId: "t-2",
  },
];
const laneMessage: Step = [
  "mux",
  "user_message",
  {
    _meta: { provenance: { kind: "unverified", fromRelay: "lane-gh" } },
    client: "acpmux-cli#77",
    promptId: "p-3",
    text: `[message 7f70dca3 from gcp-vm/lane-x (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message 7f70dca3]"]\n${LANE}\n[end of message 7f70dca3]`,
    turnId: "t-3",
  },
];
const events = record([
  ...turn("t-1", personPrompt, "Watching it."),
  ...turn("t-2", agentMessage, "Noted the nightly."),
  ...turn("t-3", laneMessage, "Noted the cloud run."),
]);

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events.
function fakeDaemon(history: ReturnType<typeof record>) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 3,
    updatedAt: START,
  };
  const answer = (method: string) => {
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
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (live: ReturnType<typeof record>) => {
    for (const event of live)
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  return { open, push };
}

/// The chat's rows: attached cold to the whole log, or attached after the first turn with the rest live.
async function rowsOf(live: boolean): Promise<AcpmuxRow[]> {
  const split = live ? 4 : events.length;
  const daemon = fakeDaemon(events.slice(0, split));
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  daemon.push(events.slice(split));
  await new Promise((resolve) => setTimeout(resolve, 0));
  client.close();
  return rows;
}

const drawnText = (rows: readonly AcpmuxRow[]) =>
  rows.filter((row) => !isVisiblyEmptyMessage(row)).map((row) => `${row.text ?? ""} ${row.incoming?.kind ?? ""}`);

for (const live of [true, false])
  test(`another agent's message and a lane's relayed message draw nothing (${live ? "live" : "cold reload"})`, async () => {
    const rows = await rowsOf(live);
    const view = turnViewFrom(rows, new Set(), { now: START + 3_600_000, agentFamily: "claude" });
    const drawn = drawnText(view.rows).join("\n");
    expect(drawn).toContain(PERSON);
    expect(drawn).toContain("Noted the nightly.");
    expect(drawn).toContain("Noted the cloud run.");
    expect(drawn).not.toContain(AGENT);
    expect(drawn).not.toContain(LANE);
    expect(view.rows.some((row) => row.incoming?.kind === "message" || row.incoming?.kind === "inbox")).toBe(false);
  });

test("a message relayed between agents is one; a person's words and a tool's notice are not", () => {
  expect(relayedBetweenAgents({ kind: "message", message: { name: "release-watch", text: AGENT } })).toBe(true);
  expect(relayedBetweenAgents({ kind: "inbox", notice: { threads: [] } })).toBe(true);
  expect(relayedBetweenAgents({ kind: "message", message: { name: "Sam", text: "hi", fromPerson: true } })).toBe(false);
  expect(
    relayedBetweenAgents({
      kind: "message",
      message: { name: "cmux", text: "", notice: { title: "Build finished" } } as never,
    }),
  ).toBe(false);
  expect(relayedBetweenAgents({ kind: "notice", text: "Task bg-1 finished" })).toBe(false);
  expect(relayedBetweenAgents({ kind: "prompt", text: PERSON })).toBe(false);
  expect(relayedBetweenAgents(undefined)).toBe(false);
});

test("an agent's message waiting in the queue draws no row; a guest's held prompt still does", () => {
  const queue = [
    { id: "q-1", prompt: AGENT, message: { name: "release-watch", text: AGENT } },
    { id: "q-2", prompt: "please look", awaitingOwner: true, author: { id: "g-1", name: "Sam", role: "guest" } },
  ] as unknown as AcpmuxSnapshot["queue"];
  const rows = queuedMessageRows(queue);
  expect(rows.map((row) => row.queuedMessage?.promptId)).toEqual(["q-2"]);
});
