// l10n-allow-file: public-safe subagent transcript fixtures, not shipped copy.
// A subagent pane opened on a subagent the chat's loaded rows no longer hold (Leo, 2026-11-07: "is
// this your sub-agent, or is this literally just a duplicate of you?"). The records are shaped as
// acpmux logged a real Claude Code background Agent and a real Codex spawn_agent on 2026-11-07.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { foldOwnLog, subagentPaneView, type OwnLogRecord } from "./subagentOwnLog";
import { SUBAGENT_EMPTY, SUBAGENT_OF } from "./subagentRows";
import { shownSubagentFacts } from "./subagentShown";

const update = (seq: number, sessionId: string, mux: Record<string, unknown>, body: Record<string, unknown>) =>
  ({
    seq,
    at: 1_000 * seq,
    dir: "in",
    kind: String(body.sessionUpdate),
    msg: { jsonrpc: "2.0", method: "session/update", params: { _meta: { acpmux: mux }, sessionId, update: body } },
  }) satisfies OwnLogRecord;
const text = (value: string) => ({ type: "text", text: value });

// A Claude Code background Agent: its id is `<session>/<its Agent call>`, its own lines stream
// under that id, and acpmux tags each with it.
const CHAT = "chat-1";
const CLAUDE = `${CHAT}/toolu_agent`;
const claudeLog: OwnLogRecord[] = [
  update(
    43,
    CHAT,
    {
      subagents: [
        {
          id: CLAUDE,
          parent: null,
          name: "Count files in tmp",
          task: "Count files in tmp",
          kind: "general-purpose",
          model: "claude-sonnet-5-5",
          state: "running",
          background: true,
          toolCallId: "toolu_agent",
        },
      ],
    },
    { sessionUpdate: "subagent_spawned", name: "Count files in tmp" },
  ),
  update(
    74,
    CLAUDE,
    { subagent: CLAUDE },
    {
      sessionUpdate: "tool_call",
      toolCallId: "toolu_bash",
      kind: "execute",
      status: "in_progress",
      title: "ls /tmp | wc -l",
      rawInput: { command: "ls /tmp | wc -l" },
      _meta: { claude: { tool: "Bash" } },
    },
  ),
  update(
    81,
    CLAUDE,
    { subagent: CLAUDE },
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "toolu_bash",
      status: "completed",
      content: [{ type: "content", content: text("42") }],
    },
  ),
  update(
    83,
    CLAUDE,
    { subagent: CLAUDE },
    { sessionUpdate: "agent_message_chunk", messageId: "msg_1", content: text("There are 42 entries in /tmp.") },
  ),
  update(
    86,
    CHAT,
    {
      subagents: [
        { id: CLAUDE, parent: null, name: "Count files in tmp", state: "completed", agentId: "a08a0dff687d3654e" },
      ],
    },
    { sessionUpdate: "subagent_state_update", state: "completed", subagentSessionId: CLAUDE },
  ),
];

// A Codex spawn_agent: its id is the child thread's, every child runs in its own thread.
const CODEX = "thread-child";
const codexLog: OwnLogRecord[] = [
  update(
    53,
    CHAT,
    { subagents: [{ id: CODEX, parent: null, name: "count_tmp", state: "running" }] },
    { sessionUpdate: "subagent_spawned", name: "count_tmp" },
  ),
  update(
    84,
    CHAT,
    { subagent: CODEX },
    {
      sessionUpdate: "tool_call",
      toolCallId: "call_1",
      kind: "execute",
      status: "in_progress",
      title: "ls /tmp | wc -l",
      rawInput: { command: "ls /tmp | wc -l" },
    },
  ),
  update(
    85,
    CHAT,
    { subagent: CODEX },
    { sessionUpdate: "tool_call_update", toolCallId: "call_1", status: "completed" },
  ),
  update(90, CHAT, { subagent: CODEX }, { sessionUpdate: "agent_message_chunk", content: text("42") }),
  update(
    96,
    CHAT,
    { subagents: [{ id: CODEX, parent: null, name: "count_tmp", state: "completed" }] },
    { sessionUpdate: "subagent_state_update", state: "completed" },
  ),
];

// The chat's own rows: the parent's words, and none of the subagent (its group is in an older page).
const chatRows: AcpmuxRow[] = [
  { id: "user-900", version: 1, at: 900, kind: "user", text: "Diagnose the nightly lag" },
  { id: "assistant-901", version: 1, at: 901, kind: "assistant", text: "Sent through the coordinator" },
];
const parentRow = (rows: readonly AcpmuxRow[]) =>
  rows.some((row) => row.id === "assistant-901" || row.id === "user-900");
const texts = (rows: readonly AcpmuxRow[]) => rows.map((row) => row.text).filter(Boolean);

for (const [harness, id, records, words, name] of [
  ["claude", CLAUDE, claudeLog, "There are 42 entries in /tmp.", "Count files in tmp"],
  ["codex", CODEX, codexLog, "42", "count_tmp"],
] as const) {
  test(`a finished ${harness} subagent the chat's rows no longer hold shows its own rows and state, never the chat's`, () => {
    const log = foldOwnLog(id, records, { session: CHAT, harness });
    expect(log.agent?.state).toBe("completed");
    expect(log.agent?.name).toBe(name);
    const rows = subagentPaneView(id, { rows: chatRows, views: {} }, { log, loading: false }, new Set(), "coordinator");
    expect(parentRow(rows)).toBe(false);
    expect(rows[0]?.kind).toBe(SUBAGENT_OF);
    expect(rows[0]?.subagents?.[0]?.state).toBe("completed");
    expect(texts(rows.slice(1))).toContain(words);
  });
}

test("a subagent whose own records are still being read shows loading, then empty, never the chat's rows", () => {
  const loading = subagentPaneView(CLAUDE, { rows: chatRows, views: {} }, { loading: true }, new Set(), "coordinator");
  expect(parentRow(loading)).toBe(false);
  expect(loading).toHaveLength(1);
  expect(loading[0]?.kind).toBe(SUBAGENT_EMPTY);
  expect(loading[0]?.status).toBe("loading");

  // The read found nothing (or failed): an empty transcript of the subagent, in the same place.
  const none = foldOwnLog(CLAUDE, [], { session: CHAT, harness: "claude" });
  const empty = subagentPaneView(CLAUDE, { rows: chatRows, views: {} }, { log: none, loading: false }, new Set(), "x");
  expect(parentRow(empty)).toBe(false);
  expect(empty[0]?.kind).toBe(SUBAGENT_EMPTY);
  expect(empty[0]?.status).toBeUndefined();
  expect(empty[0]?.id).toBe(loading[0]?.id);
});

test("a subagent the chat's rows hold draws from them, as before", () => {
  const log = foldOwnLog(CODEX, codexLog, { session: CHAT, harness: "codex" });
  const rows = subagentPaneView(CODEX, { rows: log.rows, views: log.views }, { loading: true }, new Set(), "chat");
  expect(rows[0]?.kind).toBe(SUBAGENT_OF);
  expect(texts(rows.slice(1))).toContain("42");
});

test("a subagent pane's tab gets its subagent's own state, since when and model, not its chat's", () => {
  const log = foldOwnLog(CLAUDE, claudeLog, { session: CHAT, harness: "claude" });
  const facts = shownSubagentFacts(log.agent!, 250);
  expect(facts.state).toBe("completed");
  expect(facts.model).toBe("claude-sonnet-5-5");
  // Finished: since its end, on this computer's clock.
  expect(facts.sinceMs).toBe(log.agent!.endedAt! + 250);
  const running = shownSubagentFacts({ state: "running", startedAt: 5_000 }, 0);
  expect(running).toEqual({ state: "running", sinceMs: 5_000 });
});
