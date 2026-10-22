// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Claude Code's ToolSearch only loads deferred tools' schemas; the transcript draws no row for it
// (hiddenTools.ts). A turn of ToolSearch, Read and Bash shows Read and Bash and counts two calls;
// a turn of only ToolSearch draws no tool row, so no empty "Worked for" fold. The parent
// transcript (direct.ts) and a subagent's own view (subagents/childRows.ts) both hide it.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { childRows } from "./subagents/childRows";

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

/// A Claude Code call as acpmux sends it (claude_stdio `tool_call_fields`), then its result.
const call = (id: string, tool: string, title: string, kind: string, status = "completed") => [
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
  { update: { sessionUpdate: "tool_call_update", toolCallId: id, status, _meta: { claude: { tool } } } },
];
const toolSearch = (id: string, status = "completed") => call(id, "ToolSearch", "ToolSearch", "other", status);
const say = (text: string) => ({ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });
const turn = (prompt: string, ...steps: unknown[]) => [
  { mux: "user_message", msg: { text: prompt } },
  { mux: "turn_started", msg: {} },
  ...steps,
  { mux: "turn_result", msg: { status: "completed" } },
];

const MIXED = "Find the retry helper and run its tests";
const ONLY = "Load the browser tools";

/// The rows the pane draws for each turn, from a chat whose history holds both turns.
async function turnRows(): Promise<Record<string, Row[]>> {
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
    ...turn(ONLY, ...toolSearch("search-2"), ...toolSearch("search-3", "failed"), say("Loaded.")),
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
    await until(() => Boolean(turnOf(ONLY)?.some((row) => row.kind === "turnSummary")));
    return { mixed: turnOf(MIXED)!, only: turnOf(ONLY)! };
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
  expect(only.filter((row) => row.kind === "assistant").map((row) => row.text)).toEqual(["Loaded."]);
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
