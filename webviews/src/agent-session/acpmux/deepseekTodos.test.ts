// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// DeepSeek Harness keeps its task list with `todo_write` (the whole list on every call), and its ACP
// bridge sends the call but no plan. acpmux marks the call (`_meta.acpmux.planTool`) and logs its
// list as an ACP `plan` after the call's result (acp_todo_plan.rs), so the pane draws the same
// checklist Claude, Codex and Muse get, and the call draws no row of its own (museTodos.test.ts).
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

type Todo = { content: string; status: "pending" | "in_progress" | "completed" };
const marked = { acpmux: { planTool: true } };

/// A `todo_write` call as DeepSeek Harness's ACP bridge sends it (deepseek-harness
/// packages/acp/acp/src/updates.ts: title is the tool name, kind `other`, the parsed arguments as
/// rawInput), marked by acpmux (acp_todo_plan.rs).
const todoCall = (id: string, todos: Todo[]) => ({
  update: {
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: "todo_write",
    kind: "other",
    status: "in_progress",
    rawInput: { todos },
    _meta: marked,
  },
});
const todoDone = (id: string, status = "completed") => ({
  update: {
    sessionUpdate: "tool_call_update",
    toolCallId: id,
    status,
    content: [{ type: "content", content: { type: "text", text: "Updated todo list" } }],
    _meta: marked,
  },
});
/// The plan acpmux logs after a completed call's result.
const plan = (todos: Todo[]) => ({
  update: { sessionUpdate: "plan", entries: todos.map((todo) => ({ ...todo, priority: "medium" })) },
});
const read = (id: string) => [
  { update: { sessionUpdate: "tool_call", toolCallId: id, title: "read", kind: "other", status: "in_progress" } },
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
  { content: "Write the parser", status: "in_progress" },
  { content: "Test the parser", status: "pending" },
];
const DONE: Todo[] = [
  { content: "Write the parser", status: "completed" },
  { content: "Test the parser", status: "completed" },
];
const PROMPT = "Plan and build the parser";

async function turnRows(): Promise<Row[]> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = turn(
    PROMPT,
    say("I'll plan it first. "),
    todoCall("todo-1", START),
    todoDone("todo-1"),
    plan(START),
    ...read("read-1"),
    todoCall("todo-2", DONE),
    todoDone("todo-2"),
    plan(DONE),
    say("The parser is written and tested."),
  );
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
    await until(() => rows.some((row) => row.kind === "turnSummary"));
    const start = rows.findIndex((row) => row.kind === "user" && row.text === PROMPT);
    return rows.slice(start + 1);
  } finally {
    client.close?.();
  }
}

const titles = (rows: Row[]) =>
  rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool?.title ?? []) : []));

test("DeepSeek Harness's todo_write draws one checklist that updates in place", async () => {
  const rows = await turnRows();
  const plans = rows.filter((row) => row.kind === "plan");
  expect(plans).toHaveLength(1);
  expect(plans[0].plan).toEqual([
    { content: "Write the parser", status: "completed" },
    { content: "Test the parser", status: "completed" },
  ]);
});

test("DeepSeek Harness's todo_write calls draw no tool row and count toward no summary", async () => {
  const rows = await turnRows();
  expect(titles(rows)).toEqual(["read"]);
  expect(rows.find((row) => row.kind === "turnSummary")?.toolCount).toBe(1);
});
