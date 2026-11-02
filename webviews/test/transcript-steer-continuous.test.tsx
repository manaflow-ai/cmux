// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A steer is one continuous turn. Leo sent a message while a turn ran (⌘Return) to a session whose
// agent cannot steer: acpmux puts the prompt next (`queue_order` `next`), cancels the running turn
// (`turn_result` `cancelled`) and runs the prompt as a new turn. The transcript drew that as a Stop:
// "You stopped after 55s" over the work, "Sent now · stopped the turn" under his message, and a
// fresh "Working for 18s". He never pressed Stop; with Claude a steer does not stop the turn.
//
// - The steer draws inline in the running turn, which reads "Working for" from the first prompt.
// - The cancel the steer caused is not drawn as "You stopped after", and the prompt carries no
//   mark of its own (no "Steered": #22773 removes those marks); it is accepted and drawn inline.
// - A Send now that ends the turn with `end_turn` (acpmux #22808, Claude) goes on the same way.
// - Once the turn ends, its work folds into one Worked-for disclosure; personal steers and
//   their preceding assistant replies stay visible.
//   Expanding it keeps every call, reply, and steer in its recorded order.
// - A real Stop still reads "You stopped after", also when a prompt is sent now after it.
// - Everything else that finds a turn by its prompt walks past a steer too (review of #22691): the
//   edited-files checkpoint spans the whole chain, Find and a shell's row open the fold the turn
//   draws, the hover footer is the chain's, running subagent groups and the minimap's turns count
//   the chain as one. "You stopped after" neither flashes between the cancel and the steer's
//   record nor comes back when an older history page ends at the steer.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { translate } from "../src/agent-session/acpmux/i18n";
import {
  turnFoldFor,
  turnFooterFrom,
  turnView,
  WORKED,
  WORKING,
  workedLabel,
} from "../src/agent-session/acpmux/conversation/turns";
import { endsTurn, turnRows } from "../src/agent-session/acpmux/diff";
import { readTurnFromRows } from "../src/agent-session/acpmux/changes/turnCheckpointSource";
import { runningGroups } from "../src/agent-session/acpmux/subagents/subagentRows";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";
import { endedEditRow, markRows } from "../src/agent-session/acpmux/rowMarks";

const CHAT = "0190a000-0000-7000-8000-0000000000d3";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>, atSeconds?: number];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string, messageId: string) =>
  update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } });
const call = (id: string, title: string) =>
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute", status: "completed" });

/// Records `steps`, each at its own second after START unless it names one.
const record = (steps: Step[]) => {
  let last = 0;
  return steps.map(([dir, kind, msg, atSeconds], index) => {
    last = atSeconds ?? last + 1;
    return { sessionId: CHAT, seq: index + 1, at: START + last * 1000, dir, kind, msg };
  });
};

async function rowsOf(history: ReturnType<typeof record>): Promise<AcpmuxRow[]> {
  return (await clientOf(history)).rows();
}

/// A client attached to `history`, its attach page the newest `page` events; `loadOlder` reads the rest.
async function clientOf(
  history: ReturnType<typeof record>,
  page = history.length,
  status = "running",
  held: string[] = [],
) {
  let socket: any;
  const promptRequests: string[] = [];
  let promptSent!: () => void;
  const firstPrompt = new Promise<void>((resolve) => (promptSent = resolve));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status,
    steering: false,
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return {
          session,
          lastSeq: history.at(-1)?.seq ?? 0,
          events: history.slice(-page),
          hasMore: page < history.length,
        };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const events = params?.kinds?.includes("transcript") ? history.filter((event) => event.seq < before) : [];
        return { events, hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.method === "session/prompt") {
          promptRequests.push(message.params._meta.acpmux.promptId);
          promptSent();
        }
        if (message.id !== undefined && !held.includes(message.method))
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
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  /// Live records after the attach, as acpmux streams them.
  const push = (events: ReturnType<typeof record>) => {
    for (const event of events)
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  /// The socket closes, as when acpmux restarts or the network drops.
  const drop = () => {
    socket.readyState = WebSocket.CLOSED;
    socket.onclose?.({ code: 1006, reason: "", wasClean: false });
  };
  return { client, rows: () => rows, push, drop, firstPrompt, promptRequests };
}

/// Leo's prompt runs 55s; he sends a message now; acpmux stops that turn and runs his message next.
const steerChain: Step[] = [
  ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
  ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
  ["in", "tool_call", call("t-1", "bun test login"), 20],
  ["in", "agent_message_chunk", say("The retry races the session refresh.", "m-1"), 40],
  ["mux", "queued", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 54],
  ["mux", "queue_order", { promptId: "p-2", order: ["p-2"], next: true }, 54],
  ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 55],
  ["mux", "dequeued", { promptId: "p-2" }, 55],
  ["mux", "user_message", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 55],
  ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 55],
  ["in", "tool_call", call("t-2", "bun test logout"), 70],
];

test("a steer draws inline in the running turn, whose line counts from the first prompt", async () => {
  const rows = await rowsOf(record(steerChain));
  const view = turnView(rows, new Set(), { working: true });
  const first = view.find((row) => row.kind === "user" && row.text === "Fix the flaky login test")!;
  const steer = view.find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  // One running turn: one Working line, timed from the first prompt.
  const working = view.filter((row) => row.kind === WORKING);
  expect(working).toHaveLength(1);
  expect(working[0]!.at).toBe(first.at);
  expect(view.indexOf(working[0]!)).toBeLessThan(view.indexOf(steer));
  // Nothing says the turn was stopped.
  expect(view.some((row) => row.kind === "turnSummary" && row.status === "cancelled")).toBe(false);
  expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
  expect(steer.steer).toBeUndefined();
  expect(steer.continues).toBe(true);
  expect(steer.pending).toBeFalsy();
});

test("once the chain ends, all its work folds under one stable disclosure", async () => {
  const rows = await rowsOf(
    record([
      ...steerChain,
      ["in", "agent_message_chunk", say("Both paths are fixed.", "m-2"), 80],
      ["mux", "turn_result", { status: "completed", turnId: "turn-2" }, 80],
    ]),
  );
  const first = rows.find((row) => row.kind === "user" && row.text === "Fix the flaky login test")!;
  const steerRow = rows.find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  const view = turnView(rows, new Set());
  const worked = view.filter((row) => row.kind === WORKED);
  expect(worked.map((row) => row.id)).toEqual([`${WORKED}-${first.id}`]);
  expect(worked.some((row) => row.status === "cancelled")).toBe(false);
  expect(worked.map((row) => row.durationMs)).toEqual([80_000]);
  expect(workedLabel(translate, worked[0]!)).toBe(translate("turn.worked", { time: "1m 20s" }));
  expect(view.some((row) => row.id === steerRow.id)).toBe(true);
  expect(view.some((row) => row.text === "The retry races the session refresh.")).toBe(true);
  expect(view.indexOf(worked[0]!)).toBeLessThan(view.findIndex((row) => row.text === "Both paths are fixed."));
  expect(view.filter((row) => row.kind === "turnSummary")).toHaveLength(1);
  // Nothing is dropped: open, the fold holds every tool call and steer in recorded order.
  const open = turnView(rows, new Set(worked.map((row) => row.id)));
  const toolAt = (id: string) => open.findIndex((row) => row.items?.some((item) => item.tool?.id === id));
  const steerAt = open.findIndex((row) => row.id === steerRow.id);
  expect(toolAt("t-1")).toBeGreaterThan(open.findIndex((row) => row.id === worked[0]!.id));
  expect(toolAt("t-1")).toBeLessThan(steerAt);
  expect(toolAt("t-2")).toBeGreaterThan(steerAt);
  expect(toolAt("t-2")).toBeLessThan(open.findIndex((row) => row.text === "Both paths are fixed."));
  const tools = (list: AcpmuxRow[]) =>
    list.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : []))).sort();
  expect(tools(open)).toEqual(tools(rows));
});

test("a real Stop still reads You stopped after", async () => {
  const rows = await rowsOf(
    record([
      ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
      ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
      ["in", "tool_call", call("t-1", "bun test login"), 20],
      ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 40],
      ["mux", "user_message", { text: "try again", promptId: "p-2", turnId: "turn-2" }, 60],
      ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 60],
      ["in", "tool_call", call("t-2", "bun test login --retry"), 70],
    ]),
  );
  const view = turnView(rows, new Set(), { working: true });
  const stopped = view.find((row) => row.kind === WORKED)!;
  expect(stopped.status).toBe("cancelled");
  expect(workedLabel(translate, stopped)).toBe(translate("turn.stopped", { time: "40s" }));
  const working = view.find((row) => row.kind === WORKING);
  expect(working?.at).toBe(START + 60_000);
});

test("a prompt sent now after a real Stop leaves the Stop as it was", async () => {
  // Stop ended the turn; then Send now on a queued prompt with no turn running (acpmux `next`).
  const rows = await rowsOf(
    record([
      ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
      ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
      ["in", "tool_call", call("t-1", "bun test login"), 20],
      ["mux", "queued", { text: "then the logout path", promptId: "p-2", turnId: "turn-2" }, 30],
      ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 40],
      ["mux", "queue_order", { promptId: "p-2", order: ["p-2"], next: true }, 50],
      ["mux", "dequeued", { promptId: "p-2" }, 50],
      ["mux", "user_message", { text: "then the logout path", promptId: "p-2", turnId: "turn-2" }, 50],
      ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 50],
      ["in", "tool_call", call("t-2", "bun test logout"), 60],
    ]),
  );
  const view = turnView(rows, new Set(), { working: true });
  expect(view.find((row) => row.kind === WORKED)?.status).toBe("cancelled");
  const next = view.find((row) => row.kind === "user" && row.text === "then the logout path")!;
  expect(next.steer).toBeUndefined();
  expect(view.find((row) => row.kind === WORKING)?.at).toBe(START + 50_000);
});

/// The chain ended: the steer's work, then the answer and the turn's own end. Each summary carries
/// the checkpoints acpmux took (`checkpointId` before the prompt, `endCheckpointId` at the end).
const endedChain: Step[] = [
  ...steerChain.map((step): Step =>
    step[1] === "turn_result"
      ? [step[0], step[1], { ...step[2], checkpointId: "cp-a", endCheckpointId: "cp-b" }, step[3]]
      : step,
  ),
  ["in", "agent_message_chunk", say("Both paths are fixed.", "m-2"), 80],
  ["mux", "turn_result", { status: "completed", turnId: "turn-2", checkpointId: "cp-c", endCheckpointId: "cp-d" }, 80],
];
const rowWith = (rows: AcpmuxRow[], toolId: string) =>
  rows.find((row) => row.items?.some((item) => item.tool?.id === toolId))!;

test("the edited files after a steer belong to the chain, and its checkpoint spans the chain", async () => {
  const rows = await rowsOf(record(endedChain));
  const after = rowWith(rows, "t-2");
  const turn = turnRows(rows, after.id);
  expect(turn[0]?.text).toBe("Fix the flaky login test");
  expect(turn.some((row) => row.items?.some((item) => item.tool?.id === "t-1"))).toBe(true);
  expect(turn.filter((row) => row.kind === "turnSummary")).toHaveLength(2);
  const asked: string[][] = [];
  const read = await readTurnFromRows(rows, after.id, async (from, to) => {
    asked.push([from, to]);
    return { complete: true };
  });
  expect(asked).toEqual([["cp-a", "cp-d"]]);
  expect(read && "checkpoint_id" in read ? read.checkpoint_id : undefined).toBe("cp-a..cp-d");
});

test("a native steer's turn has ended once its one summary comes, and its edits span the steer", async () => {
  let at = START;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const rows = [
    row("u", "user", { text: "Refactor the parser" }),
    row("a1", "activity", {
      items: [{ kind: "tool", text: "", tool: { id: "e1", title: "Edit a.ts", kind: "edit", status: "completed" } }],
    }),
    row("s", "user", { text: "use the cache dir", steer: "landed" }),
    row("a2", "activity", {
      items: [{ kind: "tool", text: "", tool: { id: "e2", title: "Edit b.ts", kind: "edit", status: "completed" } }],
    }),
    row("sum", "turnSummary", { status: "completed", checkpoint: { from: "cp-1", to: "cp-2" } }),
  ];
  expect(turnRows(rows, "a1").map((each) => each.id)).toEqual(["u", "a1", "s", "a2", "sum"]);
  const read = await readTurnFromRows(rows, "a1", async () => ({ complete: true }));
  expect(read && "checkpoint_id" in read ? read.checkpoint_id : undefined).toBe("cp-1..cp-2");
  // Running groups of the turn, and the minimap's one turn.
  const group = row("g", SUBAGENTS, { subagents: [{ id: "x", name: "x", state: "running" } as any] });
  expect(runningGroups([rows[0]!, group, rows[2]!, rows[3]!])).toEqual(["g"]);
  expect(minimapTurns(rows).turns).toHaveLength(1);
});

test("Find and a shell's row open the fold the turn draws, and the hover footer is the chain's", async () => {
  const rows = await rowsOf(record(endedChain));
  const first = rows.find((row) => row.kind === "user")!;
  const before = rows.indexOf(rowWith(rows, "t-1"));
  const index = rows.indexOf(rowWith(rows, "t-2"));
  // Every call opens the chain's one fold, before and after the steer.
  expect(turnFoldFor(rows, before)).toBe(`${WORKED}-${first.id}`);
  expect(turnFoldFor(rows, index)).toBe(`${WORKED}-${first.id}`);
  const view = turnView(rows, new Set());
  expect(view.some((row) => row.id === turnFoldFor(rows, before))).toBe(true);
  expect(view.some((row) => row.id === turnFoldFor(rows, index))).toBe(true);
  let footer = view[view.length - 1]!;
  for (let at = view.length - 1; at >= 0; at -= 1)
    if (view[at]!.kind === "turnSummary") {
      footer = view[at]!;
      break;
    }
  expect(turnFooterFrom(view, view.indexOf(first))).toBe(footer.id);
});

test("between the cancel and the steer's record, the turn does not read as stopped", async () => {
  const cut = record(steerChain.slice(0, 7));
  const rows = await rowsOf(cut);
  for (const working of [true, false]) {
    const view = turnView(rows, new Set(), { working });
    expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
    expect(view.some((row) => row.kind === "turnSummary" && row.status === "cancelled")).toBe(false);
  }
});

test("an older history page that ends at the steer leaves it a steer", async () => {
  const history = record(endedChain);
  // The open page starts at the sent-now prompt; the cancel it caused is in the older page.
  const from = history.findIndex((event) => event.kind === "user_message" && event.msg.promptId === "p-2");
  const { client, rows } = await clientOf(history, history.length - from);
  await client.loadOlder();
  const steer = rows().find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  expect(steer.steer).toBeUndefined();
  expect(steer.continues).toBe(true);
  const view = turnView(rows(), new Set());
  expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
  // One turn: one footer and one stable fold, including after history is paged in.
  const first = rows().find((row) => row.kind === "user" && row.text === "Fix the flaky login test")!;
  expect(view.filter((row) => row.kind === WORKED).map((row) => row.id)).toEqual([`${WORKED}-${first.id}`]);
  expect(view.filter((row) => row.kind === "turnSummary")).toHaveLength(1);
});

test("an edit before a sent-now cancel asks for its checkpoint only once the turn ends", () => {
  let at = START;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const before = [
    row("u", "user", { text: "Fix the flaky login test" }),
    row("e", "editedFiles"),
    row("cut", "turnSummary", { status: "cancelled", continued: true }),
    row("s", "user", { text: "also check the logout path", continues: true }),
  ];
  // The cancel the steer caused does not end the turn: nothing asks for a pair that is not there.
  expect(endedEditRow(markRows(before))).toBeUndefined();
  const marks = markRows(before);
  const ended = [
    ...before,
    row("a", "assistant", { text: "Both fixed." }),
    row("end", "turnSummary", { status: "completed" }),
  ];
  expect(endedEditRow(markRows(ended, marks))).toBe("e");
});

/// Records numbered from `seq` on, at `atSeconds` after START each.
const recordFrom = (seq: number, steps: Step[]) =>
  record(steps).map((event, index) => ({ ...event, seq: seq + index }));

test("an older page cut off after a Send now does not make the next real Stop read as continued", async () => {
  // The older turn's sent-now prompt never ran (acpmux restarted); the open page is a later turn.
  const older = record([
    ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 0],
    ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 0],
    ["mux", "queued", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 10],
    ["mux", "queue_order", { promptId: "p-2", order: ["p-2"], next: true }, 10],
  ]);
  const open = recordFrom(older.length + 1, [
    ["mux", "user_message", { text: "Try the parser", promptId: "p-3", turnId: "turn-3" }, 100],
    ["mux", "turn_started", { promptId: "p-3", turnId: "turn-3" }, 100],
    ["in", "tool_call", call("t-3", "bun test parser"), 110],
  ]);
  const history = [...older, ...open];
  const { client, rows, push } = await clientOf(history, open.length);
  await client.loadOlder();
  // The person presses Stop.
  push(recordFrom(history.length + 1, [["mux", "turn_result", { status: "cancelled", turnId: "turn-3" }, 120]]));
  const view = turnView(rows(), new Set());
  const stopped = view.filter((row) => row.kind === WORKED && row.status === "cancelled");
  expect(stopped).toHaveLength(1);
  expect(workedLabel(translate, stopped[0]!)).toBe(translate("turn.stopped", { time: "20s" }));
});

test("an older page read while a Send now waits leaves that Send now a steer", async () => {
  const older = record([
    ["mux", "user_message", { text: "Earlier question", promptId: "p-0", turnId: "turn-0" }, 0],
    ["mux", "turn_started", { promptId: "p-0", turnId: "turn-0" }, 0],
    ["in", "agent_message_chunk", say("Earlier answer.", "m-0"), 5],
    ["mux", "turn_result", { status: "completed", turnId: "turn-0" }, 5],
  ]);
  const open = recordFrom(older.length + 1, [
    ["mux", "user_message", { text: "Fix the flaky login test", promptId: "p-1", turnId: "turn-1" }, 10],
    ["mux", "turn_started", { promptId: "p-1", turnId: "turn-1" }, 10],
    ["in", "tool_call", call("t-1", "bun test login"), 20],
  ]);
  const history = [...older, ...open];
  const { client, rows, push } = await clientOf(history, open.length);
  // Send now while the turn runs; the older page comes in before acpmux's cancel does.
  push(
    recordFrom(history.length + 1, [
      ["mux", "queued", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 30],
      ["mux", "queue_order", { promptId: "p-2", order: ["p-2"], next: true }, 30],
    ]),
  );
  await client.loadOlder();
  push(
    recordFrom(history.length + 3, [
      ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, 31],
      ["mux", "dequeued", { promptId: "p-2" }, 31],
      ["mux", "user_message", { text: "also check the logout path", promptId: "p-2", turnId: "turn-2" }, 31],
      ["mux", "turn_started", { promptId: "p-2", turnId: "turn-2" }, 31],
    ]),
  );
  const steer = rows().find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  expect(steer.steer).toBeUndefined();
  expect(steer.continues).toBe(true);
  const view = turnView(rows(), new Set(), { working: true });
  expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
});

test("a Send now that ends the turn with end_turn goes on as the same turn", async () => {
  // acpmux #22808: Claude's Send now ends the running turn as completed, not cancelled.
  const chain = steerChain.map((step): Step =>
    step[1] === "turn_result"
      ? [step[0], step[1], { status: "completed", stopReason: "end_turn", turnId: "turn-1" }, step[3]]
      : step,
  );
  const rows = await rowsOf(record(chain));
  const view = turnView(rows, new Set(), { working: true });
  const first = view.find((row) => row.kind === "user" && row.text === "Fix the flaky login test")!;
  const steer = view.find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  expect(steer.continues).toBe(true);
  expect(view.filter((row) => row.kind === WORKED)).toHaveLength(0);
  expect(view.filter((row) => row.kind === "turnSummary")).toHaveLength(0);
  const working = view.filter((row) => row.kind === WORKING);
  expect(working).toHaveLength(1);
  expect(working[0]!.at).toBe(first.at);
});

test("a turn that failed while a Send now waited still shows its failure", async () => {
  const chain = steerChain.map((step): Step =>
    step[1] === "turn_result" ? [step[0], step[1], { status: "failed", turnId: "turn-1" }, step[3]] : step,
  );
  const rows = await rowsOf(record(chain));
  const next = rows.find((row) => row.kind === "user" && row.text === "also check the logout path")!;
  expect(next.continues).toBeUndefined();
  expect(rows.some((row) => row.kind === "turnSummary" && row.status === "failed" && !row.continued)).toBe(true);
});

/// The chain up to acpmux taking the Send now: `p-2` waits, sent now, while turn-1 runs.
const sentNow: Step[] = steerChain.slice(0, 6);
const cancelAt = (seconds: number): Step => ["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }, seconds];
/// The drawn turn of the first prompt reads "You stopped after" (timed to its answer, 40s in), and
/// its summary ends the turn.
function readsStopped(rows: AcpmuxRow[], working = false) {
  const view = turnView(rows, new Set(), { working });
  const stopped = view.filter((row) => row.kind === WORKED && row.status === "cancelled");
  expect(stopped).toHaveLength(1);
  expect(workedLabel(translate, stopped[0]!)).toBe(translate("turn.stopped", { time: "55s" }));
  const summary = rows.find((row) => row.kind === "turnSummary")!;
  expect(summary.continued).toBeUndefined();
  expect(view.some((row) => row.kind === "turnSummary" && row.status === "cancelled")).toBe(true);
}

for (const replay of [false, true]) {
  const how = replay ? "replayed" : "live";
  /// Rows after `steps`: attached at once (replayed), or the chain's start attached and the rest live.
  const after = async (steps: Step[], status = "running", end: Step[] = []) => {
    const all = record([...steps, ...end]);
    if (replay) return (await clientOf(all, all.length, status)).rows();
    const head = all.slice(0, 2);
    const { rows, push } = await clientOf(head, head.length, status);
    push(all.slice(2));
    return rows();
  };

  test(`a Send now removed before the turn ends leaves the turn stopped (${how})`, async () => {
    readsStopped(
      await after([...sentNow, ["mux", "queue_removed", { promptId: "p-2", turnId: "turn-2" }, 54], cancelAt(55)]),
    );
  });

  test(`a Send now withdrawn after the turn ended leaves the turn stopped (${how})`, async () => {
    readsStopped(
      await after([
        ...sentNow,
        cancelAt(55),
        ["mux", "queue_removed", { promptId: "p-2", turnId: "turn-2", reason: "withdrawn" }, 56],
      ]),
    );
  });

  test(`between dequeued and the Send now's record, the idle chat still reads one turn (${how})`, async () => {
    // acpmux ends the turn and reads ready, then takes the prompt from the queue (`dequeued`), then
    // checks it and records it: a snapshot drawn in that gap must not end the turn.
    const rows = await after(
      [
        ...sentNow,
        cancelAt(55),
        ["mux", "status", { status: "ready" }, 55],
        ["mux", "dequeued", { promptId: "p-2" }, 55],
      ],
      "idle",
    );
    const summary = rows.find((row) => row.kind === "turnSummary")!;
    expect(summary.continued).toBe(true);
    // Its checkpoint is asked for only once the turn ends.
    expect(endsTurn(summary)).toBe(false);
    for (const working of [false, true]) {
      const view = turnView(rows, new Set(), { working });
      expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
    }
  });

  test(`a Send now refused with its record leaves the turn stopped (${how})`, async () => {
    readsStopped(
      await after([
        ...sentNow,
        cancelAt(55),
        ["mux", "dequeued", { promptId: "p-2" }, 55],
        ["mux", "prompt_refused", { promptId: "p-2", turnId: "turn-2", error: "refused" }, 55],
      ]),
    );
  });

  test(`a Send now that runs while the chat reads idle for a moment still continues the turn (${how})`, async () => {
    const rows = await after(steerChain, "idle");
    const view = turnView(rows, new Set(), { working: true });
    expect(view.some((row) => row.kind === WORKED && row.status === "cancelled")).toBe(false);
    expect(rows.find((row) => row.text === "also check the logout path")?.continues).toBe(true);
  });
}

test("Stop, then Send now before the cancel lands: the turn reads stopped", async () => {
  const head = record(sentNow.slice(0, 4));
  const { client, rows, push } = await clientOf(head);
  await client.cancel();
  push(
    record([...sentNow, cancelAt(55)])
      .slice(4)
      .map((event, index) => ({ ...event, seq: head.length + 1 + index })),
  );
  readsStopped(rows());
});

test("a Send now whose request the dropped socket fails still continues the turn", async () => {
  // A closed socket fails every request in flight (`native.timed_out`); acpmux still holds the
  // prompt and runs it once the pane reattaches, so the turn it ended stays one with it.
  const scope = globalThis as Record<string, unknown>;
  const hadWindow = "window" in scope;
  if (!hadWindow) scope.window = globalThis;
  const head = record(sentNow.slice(0, 5));
  const { client, rows, push, drop, firstPrompt } = await clientOf(head, head.length, "running", ["session/prompt"]);
  try {
    const sent = client.send("also check the logout path", [], "p-2").catch(() => undefined);
    // The gesture reservation is asynchronous. Drop an actual in-flight request, as this
    // scenario promises, rather than assuming send() has already written to the socket.
    await firstPrompt;
    push(
      record([...sentNow, cancelAt(55), ["mux", "dequeued", { promptId: "p-2" }, 55]])
        .slice(head.length)
        .map((event, index) => ({ ...event, seq: head.length + 1 + index })),
    );
    expect(rows().find((row) => row.kind === "turnSummary")?.continued).toBe(true);
    drop();
    await sent;
    expect(rows().find((row) => row.kind === "turnSummary")?.continued).toBe(true);
  } finally {
    client.close();
    if (!hadWindow) delete scope.window;
  }
});

test("a socket dropped while the send awaits its gesture cannot receive the prompt", async () => {
  const scope = globalThis as Record<string, unknown>;
  const hadWindow = "window" in scope;
  if (!hadWindow) scope.window = globalThis;
  const head = record(sentNow.slice(0, 5));
  const { client, rows, push, drop, promptRequests } = await clientOf(head, head.length, "running");
  let release!: (ticket: string) => void;
  const ticket = new Promise<string>((resolve) => (release = resolve));
  try {
    const sent = client.send("also check the logout path", [], "p-2", undefined, ticket);
    push(
      record([...sentNow, cancelAt(55), ["mux", "dequeued", { promptId: "p-2" }, 55]])
        .slice(head.length)
        .map((event, index) => ({ ...event, seq: head.length + 1 + index })),
    );
    expect(rows().find((row) => row.kind === "turnSummary")?.continued).toBe(true);
    drop();
    release("held-gesture");
    await expect(sent).rejects.toMatchObject({ code: "native.not_connected" });
    expect(promptRequests).toEqual([]);
    expect(rows().find((row) => row.kind === "turnSummary")?.continued).toBe(true);
  } finally {
    client.close();
    if (!hadWindow) delete scope.window;
  }
});

test("a turn steered twice keeps every call under one completed-turn fold", () => {
  // Leo's live turns (2026-10-21): a call, his steer, a reply and a call, a second steer, more
  // calls, the answer. Ended, the fold holds every call; nothing is dropped or moved above a steer
  // it came after. A Claude chat draws each run on its own line instead
  // (transcript-claude-turn-groups.test.ts).
  let at = START;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 10_000),
    ...extra,
  });
  const bash = (id: string) =>
    row(`a-${id}`, "activity", {
      items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }],
    });
  const rows = [
    row("u", "user", { text: "Look at the fleet" }),
    bash("b1"),
    row("s1", "user", { text: "also the minis", steer: "landed" }),
    row("r1", "assistant", { text: "Checking the minis too." }),
    bash("b2"),
    row("s2", "user", { text: "and the runners", steer: "landed" }),
    bash("b3"),
    bash("b4"),
    row("r2", "assistant", { text: "All three are healthy." }),
    row("sum", "turnSummary", { status: "completed" }),
  ];
  // A clock just after the turn, so no date line comes before it.
  const now = { now: START + 200_000, agentFamily: "codex" };
  const view = turnView(rows, new Set(), now);
  const ids = view.map((each) => each.id);
  expect(ids).toEqual(["u", `${WORKED}-u`, "s1", "r1", "s2", "r2", "sum"]);
  expect(view.filter((each) => each.kind === WORKED).map((each) => each.durationMs)).toEqual([90_000]);
  const open = turnView(rows, new Set([`${WORKED}-u`]), now);
  expect(open.map((each) => each.id)).toEqual([
    "u",
    `${WORKED}-u`,
    "a-b1",
    "s1",
    "r1",
    "a-b2",
    "s2",
    "a-b3",
    "a-b4",
    "r2",
    "sum",
  ]);
  expect(rows.map((_, index) => turnFoldFor(rows, index))).toEqual(rows.map(() => `${WORKED}-u`));
});

test("Codex folds interim text under Worked for; Claude folds it into its run's line", () => {
  let at = START;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 10_000),
    ...extra,
  });
  const bash = (id: string) =>
    row(`a-${id}`, "activity", {
      items: [{ kind: "tool", text: "", tool: { id, title: `Run ${id}`, kind: "execute", status: "completed" } }],
    });
  const rows = [
    row("prompt", "user", { text: "Inspect the run" }),
    bash("one"),
    row("interim", "assistant", { text: "The first check is still running." }),
    bash("two"),
    row("final", "assistant", { text: "Both checks are healthy." }),
    row("summary", "turnSummary", { status: "completed" }),
  ];

  const now = START + 200_000;
  const claude = turnView(rows, new Set(), { now, agentFamily: "claude" });
  expect(claude.map((each) => each.id)).toEqual(["prompt", "a-one", "final", "summary"]);
  const run = claude.find((each) => each.id === "a-one");
  expect(run?.foldRun).toBe(true);
  expect(run?.items?.find((item) => item.kind === "note")?.text).toBe("The first check is still running.");

  const codex = turnView(rows, new Set(), { now, agentFamily: "codex" });
  expect(codex.some((each) => each.id === "interim")).toBe(false);
  expect(codex.some((each) => each.id === "final")).toBe(true);
  expect(codex.some((each) => each.kind === WORKED)).toBe(true);
});

test("Find walks past a prompt that failed to send mid-turn to the fold the turn draws", () => {
  let at = START;
  const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    kind,
    version: 1,
    at: (at += 10_000),
    ...extra,
  });
  const rows = [
    row("u", "user", { text: "Look at the fleet" }),
    row("x", "user", { text: "and the runners", failed: true }),
    row("a-b1", "activity", {
      items: [{ kind: "tool", text: "", tool: { id: "b1", title: "Run b1", kind: "execute", status: "completed" } }],
    }),
    row("r", "assistant", { text: "All healthy." }),
    row("sum", "turnSummary", { status: "completed" }),
  ];
  expect(turnFoldFor(rows, 2)).toBe(`${WORKED}-u`);
  expect(turnView(rows, new Set(), { now: START + 100_000 }).some((each) => each.id === `${WORKED}-u`)).toBe(true);
  // A chat's first prompt that failed to send still opens its turn (acpmux ran it anyway).
  const first = [{ ...rows[0]!, failed: true }, ...rows.slice(2)];
  expect(turnFoldFor(first, 1)).toBe(`${WORKED}-u`);
  const open = turnView(first, new Set([`${WORKED}-u`]), { now: START + 100_000 });
  expect(open.some((each) => each.id === "a-b1")).toBe(true);
});
