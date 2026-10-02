import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../data/acpmux";
import { deriveTurn } from "../conversation/derive";
import { isNewChat, toolItem, turnsFromRows, unifiedHunks } from "./acpmuxTurns";
import { settledTurns } from "../pane/ChatView";

const row = (fields: Partial<AcpmuxRow> & Pick<AcpmuxRow, "id" | "kind" | "at">): AcpmuxRow => ({
  version: 1,
  ...fields,
});

const workedTurn: AcpmuxRow[] = [
  row({ id: "user-1", kind: "user", at: 1_000_000, text: "fix the reconnect test" }),
  row({ id: "assistant-2", kind: "assistant", at: 1_001_000, text: "I'll look at the reconnect code." }),
  row({
    id: "activity-3",
    kind: "activity",
    at: 1_002_000,
    toolCount: 3,
    items: [
      {
        kind: "tool",
        text: "Read",
        tool: {
          id: "r1",
          title: "Read src/relay/reconnect.ts",
          kind: "read",
          status: "completed",
          locations: [{ path: "/work/src/relay/reconnect.ts" }],
        },
      },
      {
        kind: "tool",
        text: "bun test",
        tool: { id: "x1", title: "bun test reconnect", kind: "execute", status: "failed", output: "2 fail" },
      },
      {
        kind: "tool",
        text: "Edit",
        tool: {
          id: "e1",
          title: "Edit src/relay/reconnect.ts",
          kind: "edit",
          status: "completed",
          diffs: [{ path: "/work/src/relay/reconnect.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }],
        },
      },
    ],
  }),
  row({ id: "assistant-4", kind: "assistant", at: 1_050_000, text: "Fixed: the timer is cleared on open." }),
  row({ id: "summary-5", kind: "turnSummary", at: 1_076_000, status: "completed", durationMs: 76_000, toolCount: 3 }),
];

describe("turnsFromRows", () => {
  test("one turn per user row, with commentary, tools and the final answer", () => {
    const [turn] = turnsFromRows(workedTurn, "/work");
    expect(turn!.status).toBe("completed");
    expect(turn!.durationMs).toBe(76_000);
    expect(turn!.items.map((item) => item.type)).toEqual([
      "userMessage",
      "agentMessage",
      "commandExecution",
      "commandExecution",
      "fileChange",
      "agentMessage",
    ]);
    const messages = turn!.items.filter((item) => item.type === "agentMessage");
    expect(messages.map((item) => item.type === "agentMessage" && item.phase)).toEqual(["commentary", "final_answer"]);
    expect(turn!.finalAnswerStartedAtMs).toBe(1_050_000);
  });

  test("derives Codex's header, grouped activity and edited files", () => {
    const view = deriveTurn(turnsFromRows(workedTurn, "/work")[0]!, { cwd: "/work" });
    expect(view.header?.label).toBe("Worked for 1m 16s");
    expect(view.final.map((m) => m.text)).toEqual(["Fixed: the timer is cleared on open."]);
    expect(view.edits).toEqual([{ path: "src/relay/reconnect.ts", additions: 1, deletions: 1 }]);
    const group = view.activity.find((unit) => unit.kind === "group");
    expect(group?.kind === "group" && group.rows.map((r) => r.verb)).toEqual(["Read", "Ran", "Edited"]);
  });

  test("only the last turn can run, and only while acpmux says the session works", () => {
    const rows = [
      row({ id: "user-1", kind: "user", at: 1, text: "one" }),
      row({ id: "assistant-2", kind: "assistant", at: 2, text: "first" }),
      row({ id: "user-3", kind: "user", at: 3, text: "two" }),
    ];
    expect(settledTurns(turnsFromRows(rows), true).map((turn) => turn.status)).toEqual(["completed", "inProgress"]);
    expect(settledTurns(turnsFromRows(rows), false).map((turn) => turn.status)).toEqual(["completed", "completed"]);
  });

  test("a stopped turn reads as interrupted", () => {
    const rows = [
      row({ id: "user-1", kind: "user", at: 1_000, text: "go" }),
      row({ id: "summary-2", kind: "turnSummary", at: 41_000, status: "cancelled", durationMs: 40_000 }),
    ];
    expect(deriveTurn(turnsFromRows(rows)[0]!).header?.label).toBe("You stopped after 40s");
  });
});

describe("toolItem", () => {
  test("a new file becomes an add with every line added", () => {
    const item = toolItem(
      {
        kind: "tool",
        text: "",
        tool: {
          id: "w",
          title: "Write a.ts",
          kind: "edit",
          status: "completed",
          diffs: [{ path: "/w/a.ts", newText: "x\ny\n" }],
        },
      },
      "/w",
    );
    expect(item).toMatchObject({
      type: "fileChange",
      changes: [{ path: "a.ts", kind: { type: "add" }, diff: "+x\n+y" }],
    });
  });

  test("an execute call shows the script of a bash -lc command", () => {
    const item = toolItem({
      kind: "tool",
      text: "",
      tool: {
        id: "x",
        title: "Run",
        kind: "execute",
        status: "completed",
        inputSummary: JSON.stringify({ command: ["bash", "-lc", "ls -la"] }),
      },
    });
    expect(item).toMatchObject({ type: "commandExecution", command: "ls -la", exitCode: 0 });
  });

  test("other tools keep their title", () => {
    expect(
      toolItem({
        kind: "tool",
        text: "",
        tool: { id: "t", title: "set_thread_title", kind: "other", status: "failed" },
      }),
    ).toMatchObject({
      type: "mcpToolCall",
      tool: "set_thread_title",
      status: "failed",
    });
  });
});

test("unifiedHunks has one header per hunk and no file header", () => {
  expect(unifiedHunks({ path: "f", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" })).toBe(
    "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c",
  );
});

test("a session with no messages is a new chat", () => {
  expect(isNewChat({ rows: [] } as never)).toBe(true);
  expect(isNewChat({ rows: workedTurn } as never)).toBe(false);
});
