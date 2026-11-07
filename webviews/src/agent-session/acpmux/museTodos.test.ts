// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Muse Code's step-by-step plan draws as the checklist card (PlanList), the same one Claude's
// TodoWrite and Codex's plan use, and updates in place as its steps progress. Muse keeps its plan
// with its `write_todos` tool; `muse serve` reports each list as `session/todoListChanged`, which
// the cmux-muse-acp adapter sends as an ACP `plan` update (its src/acp.rs `send_plan`). The
// adapter also sends the `write_todos` call itself as a tool call named `write_todos` (its
// src/fold.rs `tool_line`, kind `edit`), before the plan. The checklist stands for that call, so
// the call draws no row, whichever order its result and the plan come in; a failed one, which
// leaves no plan, still shows.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = {
  id: string;
  kind: string;
  text?: string;
  version?: number;
  toolCount?: number;
  plan?: { content: string; status: string }[];
  items?: { kind: string; tool?: { title: string } }[];
};

type Todo = { text: string; status: "pending" | "inProgress" | "completed" };
const acpStatus = (status: Todo["status"]) =>
  status === "inProgress" ? "in_progress" : status === "completed" ? "completed" : "pending";

/// A `write_todos` call as cmux-muse-acp sends it (ACP v1, which acpmux speaks): the announce
/// with Muse's tool name, the synthesized `tool: args` title and the call's raw args string.
const todoCall = (id: string, todos: Todo[]) => ({
  update: {
    sessionUpdate: "tool_call",
    toolCallId: id,
    name: "write_todos",
    title: "write_todos",
    kind: "edit",
    status: "in_progress",
    rawInput: JSON.stringify({ todos }),
  },
});
const todoDone = (id: string, status = "completed") => ({
  update: {
    sessionUpdate: "tool_call_update",
    toolCallId: id,
    name: "write_todos",
    title: "write_todos",
    kind: "edit",
    status,
    content: [{ type: "content", content: { type: "text", text: status === "failed" ? "invalid todos" : "ok" } }],
  },
});
/// `session/todoListChanged` as the adapter maps it: the whole list, every entry medium priority.
const plan = (todos: Todo[]) => ({
  update: {
    sessionUpdate: "plan",
    entries: todos.map((todo) => ({ content: todo.text, priority: "medium", status: acpStatus(todo.status) })),
  },
});
const read = (id: string) => [
  {
    update: {
      sessionUpdate: "tool_call",
      toolCallId: id,
      name: "read_file",
      title: "read_file: src/parser.rs",
      kind: "read",
      status: "in_progress",
    },
  },
  { update: { sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" } },
];
const say = (text: string) => ({ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });
const turn = (prompt: string, ...steps: unknown[]) => [
  { mux: "user_message", msg: { text: prompt } },
  { mux: "turn_started", msg: {} },
  ...steps,
  { mux: "turn_result", msg: { status: "completed" } },
];

const START: Todo[] = [
  { text: "Write the parser", status: "inProgress" },
  { text: "Test the parser", status: "pending" },
];
const MIDDLE: Todo[] = [
  { text: "Write the parser", status: "completed" },
  { text: "Test the parser", status: "inProgress" },
];
const DONE: Todo[] = [
  { text: "Write the parser", status: "completed" },
  { text: "Test the parser", status: "completed" },
];

const PLAN = "Plan and build the parser";
const FAIL = "Update the plan";

async function turnRows(): Promise<{ plan: Row[]; fail: Row[] }> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    ...turn(
      PLAN,
      say("I'll plan it first. "),
      // The list lands before the call's result here, and after it below: both draw the same.
      todoCall("todo-1", START),
      plan(START),
      todoDone("todo-1"),
      ...read("read-1"),
      todoCall("todo-2", MIDDLE),
      todoDone("todo-2"),
      plan(MIDDLE),
      todoCall("todo-3", DONE),
      todoDone("todo-3"),
      plan(DONE),
      say("The parser is written and tested."),
    ),
    // A rejected list leaves no plan, so its call keeps its row.
    ...turn(FAIL, todoCall("todo-4", []), todoDone("todo-4", "failed"), say("That list was invalid.")),
  ];
  for (const step of steps) daemon.record(mockHost.sessionId!, step);
  let rows: Row[] = [];
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    while (!check()) await new Promise<void>((resolve) => snapshots.push(resolve));
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const turnOf = (prompt: string) => {
      const start = rows.findIndex((row) => row.kind === "user" && row.text === prompt);
      if (start < 0) return undefined;
      const end = rows.findIndex((row, index) => index > start && row.kind === "user");
      return rows.slice(start + 1, end < 0 ? undefined : end);
    };
    await until(() => Boolean(turnOf(FAIL)?.some((row) => row.kind === "turnSummary")));
    return { plan: turnOf(PLAN)!, fail: turnOf(FAIL)! };
  } finally {
    client.close?.();
  }
}

const titles = (rows: Row[]) =>
  rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool?.title ?? []) : []));

test("Muse's plan draws one checklist that updates in place as its steps progress", async () => {
  const { plan: rows } = await turnRows();
  const plans = rows.filter((row) => row.kind === "plan");
  expect(plans).toHaveLength(1);
  expect(plans[0].plan).toEqual([
    { content: "Write the parser", status: "completed" },
    { content: "Test the parser", status: "completed" },
  ]);
  // Redrawn for each of the three lists, not appended.
  expect(plans[0].version).toBe(3);
});

test("Muse's write_todos calls draw no tool row and count toward no summary", async () => {
  const { plan: rows } = await turnRows();
  expect(titles(rows)).toEqual(["read_file: src/parser.rs"]);
  expect(rows.find((row) => row.kind === "turnSummary")?.toolCount).toBe(1);
});

test("a failed write_todos, which leaves no plan, still shows its row", async () => {
  const { fail } = await turnRows();
  expect(fail.filter((row) => row.kind === "plan")).toEqual([]);
  expect(titles(fail)).toEqual(["write_todos"]);
});
