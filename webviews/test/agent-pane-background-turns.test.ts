// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A turn the agent ran on its own (acpmux `background_turn` records: a background task finished, a
// scheduled wakeup, a hook) that had nothing new to tell draws as one muted line, not a message
// (Leo, on a chat message that said only "Nothing new for you yet.": "why do you guys keep sending
// me this/get pinged to send this"). The person's own turns, and a log from before acpmux wrote
// these records, draw exactly as before.
import { expect, test } from "bun:test";
import { BACKGROUND_TURN, backgroundTurnRowId } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { messageRevealTarget, turnFoldFor, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import { OrderedRows } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { connect, fakeDaemon, record, type Step } from "./support/agentPairDaemon";

const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const ran = (id: string): Step => [
  "in",
  "tool_call",
  update({ sessionUpdate: "tool_call", toolCallId: id, title: `ls ${id}`, kind: "execute", status: "completed" }),
];
const personTurn = (text: string, reply: string, turnId: string): Step[] => [
  ["mux", "user_message", { text, turnId }],
  ["mux", "turn_started", { turnId }],
  say(reply),
  ["mux", "turn_result", { turnId, status: "completed" }],
];
const started = (id: string, trigger = "task_notification"): Step => [
  "mux",
  "background_turn",
  { state: "started", id, trigger },
];
const ended = (id: string, quiet: boolean, reason = "result", trigger = "task_notification"): Step => [
  "mux",
  "background_turn",
  { state: "ended", id, trigger, quiet, reason },
];

const drawn = (rows: AcpmuxRow[], open: string[] = []) =>
  turnView(rows, new Set(open)).filter((row) => row.kind !== "date");
const texts = (rows: AcpmuxRow[]) =>
  rows.map((row) =>
    row.kind === BACKGROUND_TURN ? `line:${row.background?.trigger}` : `${row.kind}:${row.text ?? ""}`,
  );

test("a quiet background turn is one line that opens to its rows", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Run the tests in the background", "Started them.", "t1"),
      started("bg1"),
      ran("check"),
      say("Nothing new for you yet."),
      ended("bg1", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const line = rows().find((row) => row.kind === BACKGROUND_TURN)!;
    expect(line.background).toEqual({
      id: "bg1",
      trigger: "task_notification",
      running: false,
      quiet: true,
      reason: "result",
    });
    // Its rows belong to it; the person's turn's rows do not.
    const members = rows().filter((row) => row.inBackground === "bg1");
    expect(members.map((row) => row.kind)).toEqual(["activity", "assistant"]);
    const closed = drawn(rows());
    expect(closed.some((row) => row.text === "Nothing new for you yet.")).toBe(false);
    expect(closed.filter((row) => row.kind === BACKGROUND_TURN)).toHaveLength(1);
    expect(closed.at(-1)?.kind).toBe(BACKGROUND_TURN);
    // The person's turn draws as it always has: its reply and its footer.
    expect(texts(closed).slice(0, 3)).toEqual([
      "user:Run the tests in the background",
      "assistant:Started them.",
      expect.stringMatching(/^turnSummary:/),
    ]);
    // Opened, its rows follow its line, in order.
    const open = drawn(rows(), [backgroundTurnRowId("bg1")]);
    const at = open.findIndex((row) => row.kind === BACKGROUND_TURN);
    expect(open.slice(at + 1).map((row) => row.kind)).toEqual(["activity", "assistant"]);
    expect(open.at(-1)?.text).toBe("Nothing new for you yet.");
  } finally {
    client.close();
  }
});

test("a background turn with something to say draws its rows as today, with no line", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Watch the deploy", "Watching it.", "t1"),
      started("bg2"),
      say("The deploy failed: see https://example.com/run/1. Should I roll back?"),
      ended("bg2", false),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const view = drawn(rows());
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    expect(view.at(-1)?.text).toBe("The deploy failed: see https://example.com/run/1. Should I roll back?");
    // No "Worked for" and no footer of its own: the turn before it keeps its one footer.
    expect(view.filter((row) => row.kind === "turnSummary")).toHaveLength(1);
    expect(view.some((row) => row.kind === "worked")).toBe(false);
  } finally {
    client.close();
  }
});

test("a running background turn is the compact line, marked running", async () => {
  const daemon = fakeDaemon(
    record([...personTurn("Loop on the queue", "On it.", "t1"), started("bg3", "scheduled"), ran("queue")]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const view = drawn(rows());
    const line = view.at(-1)!;
    expect(line.kind).toBe(BACKGROUND_TURN);
    expect(line.background).toEqual({ id: "bg3", trigger: "scheduled", running: true });
    expect(view.some((row) => row.kind === "activity")).toBe(false);
    // It ends quiet: the same line, no longer running.
    daemon.push(record([say("Queue empty."), ended("bg3", true, "result", "scheduled")], 7));
    const after = drawn(rows());
    expect(after.at(-1)?.background).toMatchObject({ running: false, quiet: true });
    expect(after.some((row) => row.text === "Queue empty.")).toBe(false);
  } finally {
    client.close();
  }
});

test("a prompt that interrupts a background turn starts a normal turn after it", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Start the build", "Building.", "t1"),
      started("bg4"),
      say("Still building."),
      ended("bg4", true, "prompt"),
      ...personTurn("What's the status?", "The build passed.", "t2"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    // The prompt and everything after it are the real turn's, never the background turn's.
    expect(
      rows()
        .filter((row) => row.inBackground)
        .map((row) => row.text),
    ).toEqual(["Still building."]);
    const view = drawn(rows());
    const line = view.findIndex((row) => row.kind === BACKGROUND_TURN);
    expect(texts(view.slice(line))).toEqual([
      "line:task_notification",
      "user:What's the status?",
      "assistant:The build passed.",
      expect.stringMatching(/^turnSummary:/),
    ]);
  } finally {
    client.close();
  }
});

test("a log from before background_turn records draws exactly as before", async () => {
  const steps: Step[] = [...personTurn("Run the tests", "Started them.", "t1"), ran("check"), say("Nothing new yet.")];
  const daemon = fakeDaemon(record(steps));
  const { client, rows } = await connect(daemon);
  try {
    expect(rows().some((row) => row.kind === BACKGROUND_TURN || row.inBackground !== undefined)).toBe(false);
    const view = drawn(rows());
    expect(view.at(-1)?.text).toBe("Nothing new yet.");
    expect(view.some((row) => row.kind === "activity")).toBe(true);
  } finally {
    client.close();
  }
});

test("work after a background turn ends never joins its rows", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Watch the queue", "Watching.", "t1"),
      started("bg5"),
      ran("a"),
      ended("bg5", true),
      ran("b"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const after = rows().find((row) => row.items?.some((item) => item.tool?.id === "b"))!;
    expect(after.inBackground).toBeUndefined();
    expect(after.items?.some((item) => item.tool?.id === "a")).toBe(false);
    // It draws below the closed line, never inside it.
    expect(drawn(rows()).at(-1)?.id).toBe(after.id);
  } finally {
    client.close();
  }
});

test("an older page's started record takes the rows its turn already made", () => {
  const rows = new OrderedRows();
  const make = (seq: number, id: string) => {
    rows.current = seq;
    rows.set(id, { id, version: 1, at: seq, kind: "assistant", text: id });
    rows.current = undefined;
  };
  // The newer page was read first: the turn's rows and its ended record, then a later row.
  make(5, "inside");
  rows.closeBackground(7, { id: "bg6", trigger: "scheduled", running: false, quiet: true });
  make(8, "after");
  // The older page brings the started record.
  rows.current = 3;
  expect(rows.openBackground("bg6", 3)).toEqual({ id: "bg6", trigger: "scheduled", running: false, quiet: true });
  rows.current = undefined;
  expect(rows.get("inside")?.inBackground).toBe("bg6");
  expect(rows.get("after")?.inBackground).toBeUndefined();
  expect(rows.sorted().find((row) => row.id === "inside")?.inBackground).toBe("bg6");
});

const spawned = (id: string, state = "running"): Step => [
  "in",
  "subagent_spawned",
  {
    method: "session/update",
    params: {
      update: { sessionUpdate: "subagent_spawned" },
      _meta: { acpmux: { subagents: [{ id, parent: null, name: id, state, toolCallId: `${id}-call` }] } },
    },
  },
];

// cmux#30314: a quiet turn that ends with no prose of its own must not leave its subagent group open.
test("each background turn's subagent starts a group of its own", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Keep an eye on CI", "Watching.", "t1"),
      started("bg7"),
      spawned("first"),
      ended("bg7", true),
      started("bg8"),
      spawned("second"),
      ended("bg8", false),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const groups = rows().filter((row) => row.kind === "subagents");
    expect(groups.map((row) => [row.subagents?.map((agent) => agent.id), row.inBackground])).toEqual([
      [["first"], "bg7"],
      [["second"], "bg8"],
    ]);
    // The second turn has something to say: its subagent is in sight, not in the first one's fold.
    expect(drawn(rows()).some((row) => row.subagents?.some((agent) => agent.id === "second"))).toBe(true);
  } finally {
    client.close();
  }
});

// cmux#30315: the tray's done line stands in for the group and keeps its background turn.
test("a subagent's done line folds with its quiet background turn", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Run the checks", "Started.", "t1"),
      started("bg9"),
      spawned("checker"),
      spawned("checker", "completed"),
      say("Done."),
      ended("bg9", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    // A line cached before its group was tagged (an older page read later) is made again.
    const cache = new Map();
    const untagged = rows().map((row) => (row.kind === "subagents" ? { ...row, inBackground: undefined } : row));
    expect(withSubagentLines(untagged, cache).find((row) => row.kind === SUBAGENT_DONE)?.inBackground).toBeUndefined();
    const tray = withSubagentLines(rows(), cache);
    const done = tray.find((row) => row.kind === SUBAGENT_DONE)!;
    expect(done.inBackground).toBe("bg9");
    expect(drawn([...tray]).some((row) => row.kind === SUBAGENT_DONE)).toBe(false);
    expect(drawn([...tray], [backgroundTurnRowId("bg9")]).some((row) => row.kind === SUBAGENT_DONE)).toBe(true);
  } finally {
    client.close();
  }
});

// cmux#30316: Find and a message link open the background turn's line, not the fold before it.
test("Find and a link open the background line that hides a row", async () => {
  const daemon = fakeDaemon(
    record([...personTurn("Ship it", "Shipping.", "t1"), started("bg10"), say("Still green."), ended("bg10", true)]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const all = rows();
    const at = all.findIndex((row) => row.text === "Still green.");
    expect(turnFoldFor(all, at)).toBe(backgroundTurnRowId("bg10"));
    expect(messageRevealTarget(all, drawn(all), [all[at]!.id])).toEqual({
      rowId: all[at]!.id,
      fold: backgroundTurnRowId("bg10"),
    });
    // A row of the person's own turn still opens that turn's fold.
    expect(
      turnFoldFor(
        all,
        all.findIndex((row) => row.text === "Shipping."),
      ),
    ).toBe(
      turnFoldFor(
        all,
        all.findIndex((row) => row.text === "Ship it"),
      ),
    );
  } finally {
    client.close();
  }
});

// The quiet background turn may have ended before a subagent it started. If that subagent ends
// after another person's prompt, its done line is inserted under that later turn by end time.
// It must still fold under the *original* quiet background line (cmux#30535).
test("a subagent done after the next user prompt stays folded with its owner background turn", () => {
  const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow =>
    ({ id, at, kind, version: 1, ...fields });
  const owner = "backgroundTurn-bg-cross";
  const rows: AcpmuxRow[] = [
    row("prompt-1", 1, "user", { text: "Watch CI" }),
    row("answer-1", 2, "assistant", { text: "Watching." }),
    row("summary-1", 3, "turnSummary", { status: "completed" }),
    row(owner, 4, BACKGROUND_TURN, {
      background: { id: "bg-cross", trigger: "scheduled", running: false, quiet: true },
    }),
    row("group", 5, "subagents", {
      inBackground: "bg-cross",
      subagents: [{
        id: "child-cross", parent: null, name: "CI observer", kind: "general-purpose",
        state: "completed", startedAt: 5, endedAt: 11, background: true,
      }],
    }),
    row("prompt-2", 7, "user", { text: "Show me the status" }),
    row("answer-2", 8, "assistant", { text: "Still working." }),
    row("summary-2", 9, "turnSummary", { status: "completed" }),
  ];
  const tray = withSubagentLines(rows);
  const done = tray.find((item) => item.kind === SUBAGENT_DONE)!;
  expect(done.inBackground).toBe("bg-cross");
  expect(tray.indexOf(done)).toBeGreaterThan(tray.findIndex((item) => item.id === "prompt-2"));

  // Closing the original quiet line hides only its own done line, wherever it arrived.
  const closed = drawn([...tray]);
  expect(closed.some((item) => item.id === done.id)).toBe(false);
  expect(closed.some((item) => item.id === "prompt-2")).toBe(true);
  expect(closed.some((item) => item.id === "answer-2")).toBe(true);

  // Disclosure of the original background line reveals the late completion in chronology order.
  const opened = drawn([...tray], [owner]);
  expect(opened.some((item) => item.id === done.id)).toBe(true);
  expect(opened.indexOf(opened.find((item) => item.id === done.id)!)).toBeGreaterThan(
    opened.findIndex((item) => item.id === "prompt-2"),
  );
});
