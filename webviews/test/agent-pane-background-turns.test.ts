// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A turn the agent ran on its own (acpmux `background_turn` records: a background task finished, a
// scheduled wakeup, a hook) that had nothing new to tell draws as one muted line, not a message
// (Leo, on a chat message that said only "Nothing new for you yet.": "why do you guys keep sending
// me this/get pinged to send this"). The person's own turns, and a log from before acpmux wrote
// these records, draw exactly as before.
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { BackgroundTurnLine } from "../src/agent-session/acpmux/conversation/BackgroundTurnLine";
import {
  BACKGROUND_TURN,
  backgroundTurnRecord,
  backgroundTurnRowId,
} from "../src/agent-session/acpmux/conversation/backgroundTurns";
import {
  messageRevealTarget,
  turnFoldFor,
  turnView,
  turnViewFrom,
} from "../src/agent-session/acpmux/conversation/turns";
import { withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
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
      hasRows: true,
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
    expect(view.at(-2)?.text).toBe("The deploy failed: see https://example.com/run/1. Should I roll back?");
    // No "Worked for"; acpmux sends it no turn_result, yet its reply ends on its own footer (copy,
    // fork, read aloud), as the turn before it does (conversation/backgroundTurnFooter.test.ts).
    expect(view.filter((row) => row.kind === "turnSummary")).toHaveLength(2);
    expect(view.at(-1)).toMatchObject({
      kind: "turnSummary",
      text: "The deploy failed: see https://example.com/run/1. Should I roll back?",
    });
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
    expect(line.background).toEqual({ id: "bg3", trigger: "scheduled", running: true, hasRows: true });
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
  expect(rows.openBackground("bg6", 3)).toEqual({
    ended: { id: "bg6", trigger: "scheduled", running: false, quiet: true },
    hasRows: true,
  });
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
  const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    at,
    kind,
    version: 1,
    ...fields,
  });
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
      subagents: [
        {
          id: "child-cross",
          parent: null,
          name: "CI observer",
          kind: "general-purpose",
          state: "completed",
          startedAt: 5,
          endedAt: 11,
          background: true,
        },
      ],
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

test("an earlier background owner update invalidates every later reused turn", () => {
  const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    at,
    kind,
    version: 1,
    ...fields,
  });
  const owner = "backgroundTurn-bg-reuse";
  const base: AcpmuxRow[] = [
    row("prompt-1", 1, "user", { text: "Watch CI" }),
    row("answer-1", 2, "assistant", { text: "Watching." }),
    row(owner, 3, BACKGROUND_TURN, {
      background: { id: "bg-reuse", trigger: "scheduled", running: true },
    }),
    row("owned", 4, "assistant", { text: "Still watching.", inBackground: "bg-reuse" }),
    row("summary-1", 5, "turnSummary", { status: "completed" }),
    row("prompt-2", 6, "user", { text: "Status?" }),
    row("answer-2", 7, "assistant", { text: "Still green." }),
    row("late", 8, "assistant", { text: "Background done.", inBackground: "bg-reuse" }),
    row("summary-2", 9, "turnSummary", { status: "completed" }),
    row("prompt-3", 10, "user", { text: "Ship it" }),
    row("answer-3", 11, "assistant", { text: "Shipped." }),
    row("summary-3", 12, "turnSummary", { status: "completed" }),
  ];
  const expanded = new Set<string>();
  const previous = turnViewFrom(base, expanded, { now: 100 });
  const updated = base.map((item) =>
    item.id === owner
      ? {
          ...item,
          background: { id: "bg-reuse", trigger: "scheduled", running: false, quiet: false },
        }
      : item,
  );
  const incremental = turnViewFrom(updated, expanded, { now: 100 }, previous);
  expect(incremental.rows).toEqual(turnView(updated, expanded, { now: 100 }));
  expect(incremental.rows.find((item) => item.id === "late")).toBeDefined();
});

// turnViewFrom reuses the turns before the first changed row. Opening or closing the original
// line must still draw the later turn that holds the late done line again, and a streamed row in
// the last turn must keep it hidden while the line stays closed.
test("a late subagent done line follows its line's toggles across reused turn views", () => {
  const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    at,
    kind,
    version: 1,
    ...fields,
  });
  const owner = "backgroundTurn-bg-reuse";
  const rows: AcpmuxRow[] = [
    row("prompt-1", 1, "user", { text: "Watch CI" }),
    row("answer-1", 2, "assistant", { text: "Watching." }),
    row("summary-1", 3, "turnSummary", { status: "completed" }),
    row(owner, 4, BACKGROUND_TURN, {
      background: { id: "bg-reuse", trigger: "scheduled", running: false, quiet: true },
    }),
    row("group", 5, "subagents", {
      inBackground: "bg-reuse",
      subagents: [
        {
          id: "child-reuse",
          parent: null,
          name: "CI observer",
          kind: "general-purpose",
          state: "completed",
          startedAt: 5,
          endedAt: 11,
          background: true,
        },
      ],
    }),
    row("prompt-2", 7, "user", { text: "Show me the status" }),
    row("answer-2", 8, "assistant", { text: "Still working." }),
    row("summary-2", 9, "turnSummary", { status: "completed" }),
    row("prompt-3", 20, "user", { text: "And now?" }),
    row("answer-3", 21, "assistant", { text: "Done." }),
    row("summary-3", 22, "turnSummary", { status: "completed" }),
  ];
  const tray = withSubagentLines(rows);
  const done = tray.find((item) => item.kind === SUBAGENT_DONE)!;
  expect(done.inBackground).toBe("bg-reuse");
  const shows = (view: { rows: AcpmuxRow[] }) => view.rows.some((item) => item.id === done.id);
  const now = 1_000;

  const closedSet = new Set<string>();
  const closed = turnViewFrom(tray, closedSet, { now });
  expect(shows(closed)).toBe(false);
  // Open the original line: the later turn holding the done line draws it.
  const opened = turnViewFrom(tray, new Set([owner]), { now }, closed);
  expect(shows(opened)).toBe(true);
  // Close it again from the open view: hidden again, not a stale open row.
  const closedAgain = turnViewFrom(tray, new Set<string>(), { now }, opened);
  expect(shows(closedAgain)).toBe(false);

  // A row streamed into the last turn reuses the earlier turns and keeps the done line hidden.
  const streamed = [...tray, row("answer-3b", 23, "assistant", { text: "One more thing." })];
  const next = turnViewFrom(streamed, closedSet, { now }, closed);
  expect(next.reusedRows).toBeGreaterThan(0);
  expect(shows(next)).toBe(false);
  expect(next.rows.some((item) => item.id === "answer-3b")).toBe(true);
  // ... and shows it while the line is open.
  const openSet = new Set([owner]);
  const openBase = turnViewFrom(tray, openSet, { now });
  const openNext = turnViewFrom(streamed, openSet, { now }, openBase);
  expect(openNext.reusedRows).toBeGreaterThan(0);
  expect(shows(openNext)).toBe(true);
});

// A reused turn's rows were filtered by the folds of the view they came from. When a changed row
// after them changes which background turns fold, the reused turns draw again.
test("a fold change after the reused turns draws the turns before it again", () => {
  const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
    id,
    at,
    kind,
    version: 1,
    ...fields,
  });
  const line = (quiet: boolean) =>
    row("backgroundTurn-bg-late", 12, BACKGROUND_TURN, {
      background: { id: "bg-late", trigger: "scheduled", running: false, quiet },
    });
  const lateOwned = row("late-note", 6, "assistant", { text: "Background note.", inBackground: "bg-late" });
  const head: AcpmuxRow[] = [
    row("prompt-1", 1, "user", { text: "One" }),
    row("answer-1", 2, "assistant", { text: "First." }),
    row("summary-1", 3, "turnSummary", { status: "completed" }),
    row("prompt-2", 4, "user", { text: "Two" }),
    row("answer-2", 5, "assistant", { text: "Second." }),
    lateOwned,
    row("summary-2", 7, "turnSummary", { status: "completed" }),
    row("prompt-3", 10, "user", { text: "Three" }),
    row("answer-3", 11, "assistant", { text: "Third." }),
  ];
  const folds = new Set<string>();
  const now = 1_000;
  const quiet = turnViewFrom([...head, line(true)], folds, { now });
  expect(quiet.rows.some((item) => item.id === lateOwned.id)).toBe(false);
  // The line now has something to say: it no longer folds, so its rows draw where they came.
  const fresh = turnViewFrom([...head, line(false)], folds, { now });
  expect(fresh.rows.some((item) => item.id === lateOwned.id)).toBe(true);
  const loud = turnViewFrom([...head, line(false)], folds, { now }, quiet);
  expect(loud.rows.map((item) => item.id)).toEqual(fresh.rows.map((item) => item.id));
});

// Leo (2026-11-03): "these background updates don't really expand out to anything? idk what those
// are even for". A background turn whose only events update rows that are not its own (a call an
// earlier turn started, a subagent's work) has nothing to open to.
const lineHtml = (row: AcpmuxRow) =>
  renderToStaticMarkup(createElement(BackgroundTurnLine, { row, expanded: false, onToggle: () => {} }));
const calling = (id: string): Step => [
  "in",
  "tool_call",
  update({ sessionUpdate: "tool_call", toolCallId: id, title: `ls ${id}`, kind: "execute", status: "in_progress" }),
];
const finished = (id: string): Step => [
  "in",
  "tool_call_update",
  update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
];

test("a quiet background turn with no rows of its own draws no line", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the tests", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      calling("check"),
      say("Started them."),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      started("bg-empty", "system"),
      finished("check"),
      ended("bg-empty", true, "result", "system"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    expect(rows().filter((row) => row.inBackground === "bg-empty")).toEqual([]);
    expect(drawn(rows()).some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    expect(drawn(rows(), [backgroundTurnRowId("bg-empty")]).some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
  } finally {
    client.close();
  }
});

test("a running background turn with no rows yet is a plain line, no chevron and no button", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the tests", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      calling("check"),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      started("bg-wait", "system"),
      finished("check"),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const line = drawn(rows()).find((row) => row.kind === BACKGROUND_TURN)!;
    expect(line.background).toMatchObject({ running: true });
    const html = lineHtml(line);
    expect(html).not.toContain("<button");
    expect(html).not.toContain("cv-agent-activity__chevron");
    expect(html).not.toContain("aria-expanded");
    // Its first row of its own makes it open to that row.
    daemon.push(record([say("Still running.")], 7));
    const after = drawn(rows()).find((row) => row.kind === BACKGROUND_TURN)!;
    const opened = lineHtml(after);
    expect(opened).toContain("<button");
    expect(opened).toContain("cv-agent-activity__chevron");
    const open = drawn(rows(), [after.id]);
    expect(open.at(-1)?.text).toBe("Still running.");
  } finally {
    client.close();
  }
});

// A chat's log as Leo's chat had it (2026-11-02): background tasks ended one after another, the agent
// answered each with a lone "·" in its own message, and the session's bookkeeping came between ("why
// do you still do these"). The tasks were steps a subagent ran, which acpmux weighs silent: no line
// and no dot. Turns acpmux did not weigh (an older daemon's) that ran something fold into one line.
const dotSay = (messageId: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text: "·" } }),
];
const quietTask = (id: string, work: boolean, cause?: Record<string, unknown>): Step[] => [
  ["in", "config_option_update", update({ sessionUpdate: "config_option_update", configOptions: [] })],
  cause ? ["mux", "background_turn", { state: "started", id, trigger: "task_notification", cause }] : started(id),
  ...(work ? [ran(`${id}-check`)] : []),
  dotSay(`msg-${id}`),
  ended(id, true),
];

test("a subagent's steps answered with a lone dot draw no line and no dot", async () => {
  const step = { kind: "subagent_step", status: "completed", weight: "silent", origin: "toolu_step" };
  const daemon = fakeDaemon(
    record([
      ...personTurn("Run the four suites in the background", "Started them.", "t1"),
      ...["bg-a", "bg-b", "bg-c", "bg-d"].flatMap((id) => quietTask(id, false, step)),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const dots = rows().filter((row) => row.text === "·");
    expect(dots.map((row) => row.inBackground)).toEqual(["bg-a", "bg-b", "bg-c", "bg-d"]);
    const view = drawn(rows());
    expect(view.some((row) => row.text === "·")).toBe(false);
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
  } finally {
    client.close();
  }
});

test("quiet background turns in a row that ran something fold into one counted line", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Run the four suites in the background", "Started them.", "t1"),
      ...["bg-a", "bg-b", "bg-c", "bg-d"].flatMap((id) => quietTask(id, true)),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const view = drawn(rows());
    expect(view.some((row) => row.text === "·")).toBe(false);
    const lines = view.filter((row) => row.kind === BACKGROUND_TURN);
    expect(lines).toHaveLength(1);
    expect(lines[0]!.backgroundRun).toMatchObject({ finished: 4 });
    // Opened, the four lines draw again in order, each closed on its own rows.
    const open = drawn(rows(), [lines[0]!.id]).filter((row) => row.kind === BACKGROUND_TURN);
    expect(open.map((row) => row.background?.id ?? "run")).toEqual(["run", "bg-a", "bg-b", "bg-c", "bg-d"]);
  } finally {
    client.close();
  }
});

// Weighed from the task's own event (acpmux hub/background_cause.rs; Leo, 2026-11-03: "there's
// like... background tasks worth responding to and not worth responding to"): one case per weight.
const shellCall = (id: string): Step => [
  "in",
  "tool_call",
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: "cargo test",
    kind: "execute",
    status: "completed",
    rawInput: { command: "cargo test", run_in_background: true },
  }),
];
const weighed = (id: string, cause: Record<string, unknown>): Step => [
  "mux",
  "background_turn",
  { state: "started", id, trigger: "task_notification", cause },
];
const callOf = (rows: AcpmuxRow[], id: string) =>
  rows.flatMap((row) => row.items ?? []).find((item) => item.tool?.id === id)?.tool;

test("an interim stop goes onto its call: no line, no new mark, its reply inside the call", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      shellCall("sh1"),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      weighed("bg-i", { kind: "shell", status: "interim", weight: "silent", origin: "sh1" }),
      say("Still waiting on the suite."),
      ended("bg-i", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const view = drawn(rows());
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    expect(view.some((row) => row.text === "Still waiting on the suite.")).toBe(false);
    expect(callOf(rows(), "sh1")?.reaction).toEqual({
      turn: "bg-i",
      weight: "silent",
      text: "Still waiting on the suite.",
      // An interim cause: its call is still waiting on its own background work.
      interim: true,
    });
    // A second end of the same call keeps the first one's words before its own.
    daemon.push(
      record(
        [
          weighed("bg-i2", { kind: "shell", status: "interim", weight: "silent", origin: "sh1" }),
          say("Still waiting."),
          ended("bg-i2", true),
        ],
        20,
      ),
    );
    expect(callOf(rows(), "sh1")?.reaction?.text).toBe("Still waiting on the suite.\n\nStill waiting.");
  } finally {
    client.close();
  }
});

test("a final result marks its call new until the next prompt; a reply with something to say draws", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      shellCall("sh2"),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      weighed("bg-r", { kind: "shell", status: "completed", weight: "result", origin: "sh2" }),
      say("All 412 tests passed."),
      ended("bg-r", true),
      weighed("bg-r2", { kind: "shell", status: "completed", weight: "result", origin: "sh2" }),
      say("The suite passed, but the bench regressed 12%:\n\nShould I bisect it?"),
      ended("bg-r2", false),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const view = drawn(rows());
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    // The quiet reply is on the call; the one with something to say draws as a message.
    expect(view.some((row) => row.text === "All 412 tests passed.")).toBe(false);
    expect(view.at(-1)?.text).toContain("Should I bisect it?");
    expect(callOf(rows(), "sh2")?.reaction).toMatchObject({ weight: "result", fresh: true });
    daemon.push(record(personTurn("Yes, bisect", "Bisecting.", "t2"), 30));
    expect(callOf(rows(), "sh2")?.reaction?.fresh).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a failure always draws its line, named by the task's own summary", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      shellCall("sh3"),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      weighed("bg-f", {
        kind: "shell",
        status: "failed",
        weight: "failure",
        origin: "sh3",
        summary: "Background command failed (exit code 1)",
      }),
      say("."),
      ended("bg-f", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const line = drawn(rows()).find((row) => row.kind === BACKGROUND_TURN)!;
    expect(line.background?.cause?.weight).toBe("failure");
    expect(lineHtml(line)).toContain("Background command failed (exit code 1)");
    expect(callOf(rows(), "sh3")?.reaction).toBeUndefined();
  } finally {
    client.close();
  }
});

test("a silent turn no call took still keeps a line when it had something to say", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Watch it", "Watching.", "t1"),
      weighed("bg-m", { kind: "monitor", status: "completed", weight: "silent", origin: "gone" }),
      say("CI moved to step 3 of 5.\n\nNothing to do yet."),
      ended("bg-m", false),
      weighed("bg-q", { kind: "monitor", status: "completed", weight: "silent", origin: "gone" }),
      say("Tick."),
      ended("bg-q", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const lines = drawn(rows()).filter((row) => row.kind === BACKGROUND_TURN);
    expect(lines.map((row) => row.background?.id)).toEqual(["bg-m"]);
    // Find opens the quiet one: its line draws while open, so it can close again.
    const open = drawn(rows(), [backgroundTurnRowId("bg-q")]);
    expect(open.some((row) => row.text === "Tick.")).toBe(true);
    expect(open.some((row) => row.background?.id === "bg-q")).toBe(true);
  } finally {
    client.close();
  }
});

test("a record's cause is read whole or not at all", () => {
  expect(
    backgroundTurnRecord({
      state: "started",
      id: "b",
      trigger: "task_notification",
      cause: { kind: "subagent", status: "completed", weight: "result", origin: "c", summary: "Done" },
    })?.cause,
  ).toEqual({ kind: "subagent", status: "completed", weight: "result", origin: "c", summary: "Done" });
  for (const cause of [undefined, "x", { kind: "shell", status: "completed", weight: "loud" }, { weight: "silent" }])
    expect(
      backgroundTurnRecord({ state: "started", id: "b", trigger: "task_notification", cause })?.cause,
    ).toBeUndefined();
});

test("a subagent's final report marks its done line new; its quiet reply goes with it", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Review the PR in the background", "Started a reviewer.", "t1"),
      spawned("reviewer"),
      spawned("reviewer", "completed"),
      weighed("bg-s", { kind: "subagent", status: "completed", weight: "result", origin: "reviewer-call" }),
      say("Reviewer says SHIP."),
      ended("bg-s", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const agent = rows()
      .flatMap((row) => row.subagents ?? [])
      .find((entry) => entry.id === "reviewer");
    expect(agent?.reaction).toMatchObject({ weight: "result", fresh: true, text: "Reviewer says SHIP." });
    const view = drawn(rows());
    expect(view.some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
    expect(view.some((row) => row.text === "Reviewer says SHIP.")).toBe(false);
  } finally {
    client.close();
  }
});

// Review follow-up on #33283: a done line already drawn takes its reaction's mark when it comes, and
// drops it after the next prompt.
test("a subagent's done line draws its reaction's mark as it comes and goes", async () => {
  const daemon = fakeDaemon(
    record([...personTurn("Review it", "Started a reviewer.", "t1"), spawned("rev"), spawned("rev", "completed")]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const cache = new Map();
    const done = () => withSubagentLines(rows(), cache).find((row) => row.kind === SUBAGENT_DONE)!;
    const before = done();
    expect(before.subagents?.[0]?.reaction).toBeUndefined();
    daemon.push(
      record(
        [
          weighed("bg-rev", { kind: "subagent", status: "completed", weight: "result", origin: "rev-call" }),
          say("Reviewer says SHIP."),
          ended("bg-rev", true),
        ],
        20,
      ),
    );
    const marked = done();
    expect(marked.version).not.toBe(before.version);
    expect(marked.subagents?.[0]?.reaction).toMatchObject({ fresh: true, text: "Reviewer says SHIP." });
    daemon.push(record(personTurn("Merge it", "Merging.", "t2"), 40));
    expect(done().subagents?.[0]?.reaction?.fresh).toBeUndefined();
  } finally {
    client.close();
  }
});

// #33375: a later update of the call keeps its reaction; a task that ends after a newer prompt
// still finds its call.
test("a background reaction survives the call's later updates and a newer prompt", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      shellCall("sh9"),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      ...personTurn("Meanwhile, what's next?", "The bench.", "t2"),
      weighed("bg-late", { kind: "shell", status: "completed", weight: "result", origin: "sh9" }),
      say("All 412 tests passed."),
      ended("bg-late", true),
      ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: "sh9", status: "completed" })],
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    expect(callOf(rows(), "sh9")?.reaction).toMatchObject({ weight: "result", text: "All 412 tests passed." });
    expect(drawn(rows()).some((row) => row.kind === BACKGROUND_TURN)).toBe(false);
  } finally {
    client.close();
  }
});

// #33319: a failure that ended with something to say keeps its named line over its rows, so a long
// reply never hides what failed. The line heads rows that already show, so it opens nothing.
test("a failure with a long reply keeps its named line over the reply", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite", turnId: "t1" }],
      ["mux", "turn_started", { turnId: "t1" }],
      shellCall("sh4"),
      ["mux", "turn_result", { turnId: "t1", status: "completed" }],
      weighed("bg-fl", {
        kind: "shell",
        status: "failed",
        weight: "failure",
        origin: "sh4",
        summary: "Background command failed (exit code 101)",
      }),
      say("The suite failed in three crates.\n\nHere is what broke, crate by crate, and what I would try first."),
      ended("bg-fl", false),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const view = drawn(rows());
    const at = view.findIndex((row) => row.kind === BACKGROUND_TURN);
    expect(at).toBeGreaterThanOrEqual(0);
    const line = view[at]!;
    expect(lineHtml(line)).toContain("Background command failed (exit code 101)");
    expect(lineHtml(line)).not.toContain("aria-expanded");
    expect(lineHtml(line)).toContain('data-background-turn="failed"');
    expect(view.slice(at + 1).some((row) => row.text?.includes("Here is what broke"))).toBe(true);
  } finally {
    client.close();
  }
});

// #33538: a subagent's quiet reply to its end is text under its done line, which Find reads, not
// only its tooltip.
test("a subagent done line's reply is text under the line, not only a tooltip", async () => {
  const daemon = fakeDaemon(
    record([
      ...personTurn("Review it", "Started a reviewer.", "t1"),
      spawned("rev2"),
      spawned("rev2", "completed"),
      weighed("bg-rev2", { kind: "subagent", status: "completed", weight: "result", origin: "rev2-call" }),
      say("Reviewer says SHIP at the head."),
      ended("bg-rev2", true),
    ]),
  );
  const { client, rows } = await connect(daemon);
  try {
    const row = withSubagentLines(rows(), new Map()).find((row) => row.kind === SUBAGENT_DONE)!;
    const html = renderToStaticMarkup(createElement(SubagentDoneLine, { row }));
    expect(html).toContain('<p class="cv-reaction-reply">Reviewer says SHIP at the head.</p>');
    expect(html).not.toMatch(/title="[^"]*Reviewer says SHIP/);
  } finally {
    client.close();
  }
});
