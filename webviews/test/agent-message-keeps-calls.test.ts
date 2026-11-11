// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// Another agent's message that arrives while the agent works (acpmux steers it into the running
// turn) keeps the reply before it in sight once the turn ends (turns.ts `repliesIn`), so the closed
// "Worked for" draws the work between the two replies beside it (`aroundReplies`). That stretch
// dropped the received message's line, and any run that also edited a file went whole to the
// edited-files card, which draws only the files: its commands were gone. The two replies then sat
// next to each other with the first one's reply room between them, an empty double gap.
//
// Since 2026-11-10 a closed "Worked for" draws nothing beside it but the replies, as chatgpt.com
// does (turn-fold-hides-every-call.test.ts): the stretch is checked opened, where it must still hold
// the received message and every command, and closed, where nothing between the replies may be an
// empty row.
//
// Leo, 2026-11-07: "I think some of the tool calls, like, literally just get swallowed. They get
// deleted completely when you, like, finish up a thing or whatever. Like in this particular
// instance, I see that there's this, like, double gap here. It was like, you received a message
// from a GCP thing, and that tool call has completely disappeared."
//
// The events follow a real acpmux log (a Claude chat, 2026-11-07), with names and text replaced.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { LANE_NOTICE_BATCH, MESSAGE_RUN, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";

const CHAT = "0190a000-0000-7000-8000-0000000000c7";
const TURN = "0190a000-0000-7000-8000-00000000c701";
const START = Date.UTC(2026, 10, 7, 13, 0, 0);
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
const call = (id: string, title: string, kind: string, rawInput: Record<string, unknown>): Step[] => [
  ["in", "tool_call", update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status: "pending", rawInput })],
  ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "in_progress" })],
];
const done = (id: string): Step => [
  "in",
  "tool_call_update",
  update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
];
const bash = (id: string, command: string) => call(id, command, "execute", { command });
const write = (id: string, path: string): Step[] => [
  [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: `Write ${path}`,
      kind: "edit",
      status: "pending",
      rawInput: { file_path: path, content: "note\n" },
      content: [{ type: "diff", path, oldText: null, newText: "note\n" }],
      locations: [{ path }],
    }),
  ],
];

/// Another chat's message steered into the running turn, as acpmux records it (provenance
/// `agent_message`, `steer: true`).
const AGENT_TEXT = "cloud-reviewer: the cloud run is green at 4910f9a0.";
const agentMessage: Step = [
  "mux",
  "user_message",
  {
    _meta: {
      _acpmuxMessage: {
        message: {
          at: START,
          messageId: "0190a000-0000-7000-8000-00000000aa01",
          receiverId: CHAT,
          recordSenderCopy: false,
          sender: {
            label: "cloud-reviewer",
            name: "cloud-reviewer",
            sessionId: "0190a000-0000-7000-8000-00000000bb01",
          },
          text: AGENT_TEXT,
        },
      },
      provenance: {
        from: "fromAgent",
        fromHarness: "codex",
        fromName: "cloud-reviewer",
        fromSessionId: "0190a000-0000-7000-8000-00000000bb01",
        kind: "agent_message",
        to: CHAT,
      },
    },
    client: "acpmux-peer#0190a0",
    promptId: "0190a000-0000-7000-8000-00000000aa02",
    steer: true,
    text: AGENT_TEXT,
    turnId: TURN,
  },
];
const prompt: Step = ["mux", "user_message", { text: "Watch the cloud run and report", promptId: "p-1", turnId: TURN }];
const opened: Step = ["mux", "turn_started", { turnId: TURN, promptId: "p-1" }];
const ended: Step = ["mux", "turn_result", { status: "completed", turnId: TURN }];
/// A reply long enough to be a takeaway (turns.ts `isTakeaway`), which the closed fold keeps in sight.
const FIRST =
  "The cloud run is still building: the compile check passed and the gallery shard is halfway through its states, with no failures so far. Next check in about 25 minutes.";
const LAST = "I sent the result to the other session.";

/// The message comes in while a command runs; the command finishes after it.
const runningCall = record([
  prompt,
  opened,
  ...bash("call-1", "sleep 5; gh run view 42"),
  say("m-1", FIRST),
  ...bash("call-2", "cmux-ci status --run 42"),
  agentMessage,
  done("call-2"),
  say("m-2", LAST),
  ended,
]);

/// The message comes in after a step that ran commands and wrote a file.
const mixedRun = record([
  prompt,
  opened,
  ...bash("call-1", "gh run view 42"),
  say("m-1", FIRST),
  ...bash("call-2", "printf 'status\\n'"),
  done("call-2"),
  ...write("call-3", "/home/dev/notes/status.md"),
  done("call-3"),
  ...bash("call-4", "echo done >> /home/dev/notes/index.md"),
  done("call-4"),
  agentMessage,
  say("m-2", LAST),
  ended,
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
    turnCount: 1,
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
  const push = (events: ReturnType<typeof record>) => {
    for (const event of events)
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  return { open, push };
}

/// The chat's rows once the turn ended: attached cold to the whole log, or attached before the
/// agent's message came and handed the rest live.
async function rowsOf(events: ReturnType<typeof record>, live: boolean): Promise<AcpmuxRow[]> {
  const split = live ? events.findIndex((event) => event.kind === "user_message" && event.msg.steer) : events.length;
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

/// What a drawn row stands for: its own id, the calls it lists, and the rows a folded line holds.
function holds(row: AcpmuxRow): string[] {
  return [
    row.id,
    ...(row.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])),
    ...(row.messageRun?.rows ?? []),
    ...(row.messageRun?.work ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])),
    ...(row.laneNoticeBatch?.rows.map((member) => member.id) ?? []),
    ...(row.joined ?? []),
  ];
}

/// A row between two replies that draws something: a tool line with a call, a folded message run, or
/// another agent's line.
const drawsSomething = (row: AcpmuxRow) =>
  (row.kind === "activity" && (row.items ?? []).some((item) => item.tool)) ||
  row.kind === MESSAGE_RUN ||
  row.kind === LANE_NOTICE_BATCH ||
  (row.kind === "user" && row.incoming !== undefined);

/// The finished turn's closed fold, as a Claude chat draws it, and what sits between its two replies.
function between(rows: AcpmuxRow[], open = true) {
  const closed = turnViewFrom(rows, new Set(), { now: START + 3_600_000, agentFamily: "claude" });
  const worked = closed.rows.find((row) => row.kind === "worked")!;
  const view = open
    ? turnViewFrom(rows, new Set([worked.id]), { now: START + 3_600_000, agentFamily: "claude" })
    : closed;
  const first = view.rows.findIndex((row) => row.kind === "assistant" && row.text === FIRST);
  const last = view.rows.findIndex((row) => row.kind === "assistant" && row.text === LAST);
  expect(first).toBeGreaterThanOrEqual(0);
  expect(last).toBeGreaterThan(first);
  return view.rows.slice(first + 1, last);
}

const received = (rows: AcpmuxRow[]) => rows.find((row) => row.kind === "user" && row.incoming !== undefined)!;

for (const live of [true, false])
  test(`a command running when another agent's message came stays between the replies once the turn ends (${live ? "live" : "cold reload"})`, async () => {
    const rows = await rowsOf(runningCall, live);
    expect(received(rows)).toBeDefined();
    // Closed, nothing between the two replies draws empty.
    expect(between(rows, false).filter((row) => !drawsSomething(row))).toEqual([]);
    const drawn = between(rows);
    // Something sits between the two replies, and every row there draws: no empty gap.
    expect(drawn.length).toBeGreaterThan(0);
    expect(drawn.filter((row) => !drawsSomething(row))).toEqual([]);
    const shown = drawn.flatMap(holds);
    expect(shown).toContain("call-2");
    expect(shown).toContain(received(rows).id);
  });

for (const live of [true, false])
  test(`commands in a step that also wrote a file stay in sight beside the edited-files card (${live ? "live" : "cold reload"})`, async () => {
    const rows = await rowsOf(mixedRun, live);
    const drawn = between(rows);
    expect(drawn.length).toBeGreaterThan(0);
    expect(drawn.filter((row) => !drawsSomething(row))).toEqual([]);
    const shown = drawn.flatMap(holds);
    expect(shown).toContain("call-2");
    expect(shown).toContain("call-4");
    expect(shown).toContain(received(rows).id);
    // The file it wrote stays on the turn's edited-files card, once.
    const view = turnViewFrom(rows, new Set(), { now: START + 3_600_000, agentFamily: "claude" });
    const card = view.rows.filter((row) => row.kind === "activity" && row.items?.some((i) => i.tool?.id === "call-3"));
    expect(card.length).toBe(1);
    expect(drawn).not.toContain(card[0]);
  });
