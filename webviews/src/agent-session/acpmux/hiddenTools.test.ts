// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Claude Code's ToolSearch only loads deferred tools' schemas; the transcript draws no row for it
// (hiddenTools.ts). A turn of ToolSearch, Read and Bash shows Read and Bash and counts two calls;
// a turn of only ToolSearch draws no tool row, so no empty "Worked for" fold. The parent
// transcript (direct.ts), a subagent's own view (subagents/childRows.ts) and its group row's
// current action (subagents/subagentFold.ts) all hide it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { childRows } from "./subagents/childRows";
import { SubagentFold } from "./subagents/subagentFold";

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
  // Put back exactly what was there: a global that was absent stays absent for later files.
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = { record: (target: string, step: unknown, at?: number) => unknown };
type Row = {
  id: string;
  kind: string;
  text?: string;
  toolCount?: number;
  items?: { kind: string; tool?: { title: string } }[];
};

/// A Claude Code call as acpmux sends it (claude_stdio `tool_call_fields`), then its result, which
/// names no tool (inbound.rs): ToolSearch's schemas are `tool_reference` blocks, so its text is empty.
const call = (id: string, tool: string, title: string, kind: string, status = "completed", output = "done") => [
  {
    update: {
      sessionUpdate: "tool_call",
      toolCallId: id,
      title,
      kind,
      status: "in_progress",
      rawInput: {},
      _meta: { claude: { tool } },
    },
  },
  {
    update: {
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status,
      content: [{ type: "content", content: { type: "text", text: output } }],
    },
  },
];
const toolSearch = (id: string, status = "completed") => call(id, "ToolSearch", "ToolSearch", "other", status, "");
const say = (text: string) => ({ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });
const turn = (prompt: string, ...steps: unknown[]) => [
  { mux: "user_message", msg: { text: prompt } },
  { mux: "turn_started", msg: {} },
  ...steps,
  { mux: "turn_result", msg: { status: "completed" } },
];

const MIXED = "Find the retry helper and run its tests";
const ONLY = "Load the browser tools";
const SPLIT = "Read the retry helper";
const OTHER = "Search the tracker";

/// The rows the pane draws for each turn, from a chat whose history holds both turns.
async function turnRows(): Promise<{ mixed: Row[]; only: Row[]; split: Row[]; other: Row[] }> {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const steps = [
    ...turn(
      MIXED,
      ...toolSearch("search-1"),
      ...call("read-1", "Read", "Read retry.ts", "read"),
      ...call("bash-1", "Bash", "bun test src/net", "execute"),
      say("The retry tests pass."),
    ),
    ...turn(
      ONLY,
      say("Loading the tools. "),
      ...toolSearch("search-2"),
      ...toolSearch("search-3", "failed"),
      say("Loaded."),
    ),
    // A page that starts between a ToolSearch call and its result: only the result is here.
    ...turn(
      SPLIT,
      toolSearch("search-4")[1],
      { update: { sessionUpdate: "tool_call_update", toolCallId: "search-5", status: "failed" } },
      // A failed ToolSearch's result keeps its error text and still names no tool.
      {
        update: {
          sessionUpdate: "tool_call_update",
          toolCallId: "search-6",
          status: "failed",
          content: [{ type: "content", content: { type: "text", text: "No matching deferred tools found" } }],
        },
      },
      // A real edit whose start is on the older page still shows the file it changed.
      {
        update: {
          sessionUpdate: "tool_call_update",
          toolCallId: "edit-0",
          status: "completed",
          content: [{ type: "diff", path: "/repo/src/net/retry.ts", oldText: "a", newText: "b" }],
        },
      },
      ...call("read-2", "Read", "Read retry.ts", "read"),
      say("Read it."),
    ),
    // The ACP adapter names the tool in `_meta.claudeCode.toolName`; a bare title is any tool's.
    ...turn(
      OTHER,
      {
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "adapter-1",
          title: "ToolSearch",
          kind: "other",
          status: "completed",
          _meta: { claudeCode: { toolName: "ToolSearch" } },
        },
      },
      {
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "mcp-1",
          title: "ToolSearch",
          kind: "other",
          status: "completed",
        },
      },
      say("Searched."),
    ),
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
    await until(() => Boolean(turnOf(OTHER)?.some((row) => row.kind === "turnSummary")));
    return { mixed: turnOf(MIXED)!, only: turnOf(ONLY)!, split: turnOf(SPLIT)!, other: turnOf(OTHER)! };
  } finally {
    client.close?.();
  }
}

const titles = (rows: Row[]) =>
  rows.flatMap((row) => (row.kind === "activity" ? (row.items ?? []).flatMap((item) => item.tool?.title ?? []) : []));

test("a turn of ToolSearch, Read and Bash draws Read and Bash, and counts two calls", async () => {
  const { mixed, only } = await turnRows();
  expect(titles(mixed)).toEqual(["Read retry.ts", "bun test src/net"]);
  expect(mixed.find((row) => row.kind === "turnSummary")?.toolCount).toBe(2);

  // Only ToolSearch, done or failed: no activity row at all, so nothing folds into "Worked for".
  expect(only.filter((row) => row.kind === "activity")).toEqual([]);
  expect(only.find((row) => row.kind === "turnSummary")?.toolCount).toBe(0);
  // The reply a hidden call sits in reads on as one message.
  expect(only.filter((row) => row.kind === "assistant").map((row) => row.text)).toEqual(["Loading the tools. Loaded."]);
});

test("a hidden call's result on a page without its call draws no row named by its id", async () => {
  const { split } = await turnRows();
  // Empty, bare-failed and error-text results of calls on an older page draw nothing; an edit's
  // result still shows the file it changed.
  expect(titles(split)).toEqual(["edit-0", "Read retry.ts"]);
  expect(split.find((row) => row.kind === "turnSummary")?.toolCount).toBe(2);
});

test("the ACP adapter's ToolSearch is hidden too; another tool titled ToolSearch is not", async () => {
  const { other } = await turnRows();
  expect(titles(other)).toEqual(["ToolSearch"]);
  expect(other.find((row) => row.kind === "turnSummary")?.toolCount).toBe(1);
});

test("a subagent's own view draws no ToolSearch row either", () => {
  const entries = [...toolSearch("s-1"), ...call("r-1", "Read", "Read retry.ts", "read")].map((step, index) => ({
    event: { seq: index + 1, at: 1_000 + index },
    update: step.update,
  }));
  const rows = childRows("child", entries, new Map(), 1) as Row[];
  expect(titles(rows)).toEqual(["Read retry.ts"]);
  expect(rows.find((row) => row.kind === "activity")?.toolCount).toBe(1);

  const searchOnly = toolSearch("s-2", "failed").map((step, index) => ({
    event: { seq: index + 1, at: 1_000 + index },
    update: step.update,
  }));
  expect(childRows("child", searchOnly, new Map(), 1)).toEqual([]);
});

test("a subagent calling ToolSearch never shows it as what the subagent is doing", () => {
  const fold = new SubagentFold();
  let seq = 0;
  const feed = (update: any, acpmux: Record<string, unknown>) => {
    seq += 1;
    fold.reduce(
      { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
      update,
    );
  };
  feed({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Audit" }] });
  for (const step of call("r-2", "Read", "Read retry.ts", "read")) feed(step.update, { subagent: "a" });
  for (const step of toolSearch("s-3")) feed(step.update, { subagent: "a" });
  // Claude's progress with no summary names its last tool.
  feed({ sessionUpdate: "subagent_progress" }, { subagents: [{ id: "a", action: "ToolSearch" }] });
  const audit = fold.takeRows().flatMap((row) => row.subagents ?? []);
  expect(audit.map((agent) => agent.action)).toEqual(["Read retry.ts"]);
});

test("a later call reusing a ToolSearch call's id draws and becomes the action (ids repeat per prompt)", () => {
  // An adapter that numbers calls per process reuses an id in a later prompt (cx-jzhka).
  const entries = [...toolSearch("same"), ...call("same", "Read", "Read retry.ts", "read")].map((step, index) => ({
    event: { seq: index + 1, at: 1_000 + index },
    update: step.update,
  }));
  expect(titles(childRows("child", entries, new Map(), 1) as Row[])).toEqual(["Read retry.ts"]);

  const fold = new SubagentFold();
  let seq = 0;
  const feed = (update: any, acpmux: Record<string, unknown>) => {
    seq += 1;
    fold.reduce(
      { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
      update,
    );
  };
  feed({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "a", parent: null, name: "Audit" }] });
  for (const step of toolSearch("same")) feed(step.update, { subagent: "a" });
  for (const step of call("same", "ToolSearch", "ToolSearch", "other")) {
    // An MCP tool titled ToolSearch, no Claude meta: a real call.
    const { _meta, ...update } = step.update as any;
    feed(update, { subagent: "a" });
  }
  const audit = fold.takeRows().flatMap((row) => row.subagents ?? []);
  expect(audit.map((agent) => agent.action)).toEqual(["ToolSearch"]);
});
