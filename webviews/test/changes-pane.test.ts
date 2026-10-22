// A turn's changes in a pane of their own (turnChanges/changesPane.ts): the `changes:` reveal the
// app sends that pane names the turn's row and the file to show first, and the page asks the app
// for that pane with `chat.changesPane`, showing the changes in place when none opened.
import { expect, test } from "bun:test";
import {
  CHANGES_REVEAL,
  openChangesPane,
  requestedRow,
  revealedChanges,
  rowTool,
} from "../src/agent-session/acpmux/turnChanges/changesPane";

const prompt = (id: string) => ({ id, version: 1, at: 0, kind: "user", text: "go" }) as never;
const activity = (id: string, tools: string[] = []) =>
  ({
    id,
    version: 1,
    at: 0,
    kind: "activity",
    items: tools.map((tool) => ({ kind: "tool", text: "", tool: { id: tool, title: "Edit", status: "completed" } })),
  }) as never;

test("a changes reveal names the chat, the row, its tool call and the file", () => {
  // The app's AgentChangesPane.reveal: every field on its own line, empty when absent.
  expect(revealedChanges(`${CHANGES_REVEAL}chat-1\nrow-7\ntool-3\n/private/tmp/scratch/batch103.sh`)).toEqual({
    sessionId: "chat-1",
    rowId: "row-7",
    toolId: "tool-3",
    path: "/private/tmp/scratch/batch103.sh",
  });
  expect(revealedChanges(`${CHANGES_REVEAL}chat-1\nrow-7\n\n`)).toEqual({ sessionId: "chat-1", rowId: "row-7" });
  expect(revealedChanges(`${CHANGES_REVEAL}chat-1\nrow-7`)).toEqual({ sessionId: "chat-1", rowId: "row-7" });
});

test("a request finds its row again by its tool call after paging renames it", () => {
  const before = [activity("activity-500", ["tool-3", "tool-4"])];
  expect(rowTool(before, "activity-500")).toBe("tool-3");
  const request = { sessionId: "chat-1", rowId: "activity-500", toolId: "tool-3" };
  expect(requestedRow(before, request)).toBe("activity-500");
  // Older history paged in: the same run of tool calls is now activity-2.
  const after = [prompt("user-1"), activity("activity-2", ["tool-1", "tool-3", "tool-4"])];
  expect(requestedRow(after, request)).toBe("activity-2");
  // A reused id that no longer holds the tool call is not the row.
  expect(requestedRow([activity("activity-500", ["tool-9"])], request)).toBeUndefined();
  // A row with no tool call is found by its id.
  expect(requestedRow(after, { sessionId: "chat-1", rowId: "user-1" })).toBe("user-1");
});

test("other reveals, and one missing its chat or row, are not changes", () => {
  expect(revealedChanges("turn-12")).toBeUndefined();
  expect(revealedChanges("subagent:abc")).toBeUndefined();
  expect(revealedChanges(CHANGES_REVEAL)).toBeUndefined();
  expect(revealedChanges(`${CHANGES_REVEAL}chat-1`)).toBeUndefined();
  expect(revealedChanges(`${CHANGES_REVEAL}\nrow-7\n/a.txt`)).toBeUndefined();
});

test("the page asks for the pane and reads whether one opened", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const opened = await openChangesPane(
    async (method, params) => {
      calls.push([method, params]);
      return { opened: true };
    },
    "chat-1",
    "row-7",
    "tool-3",
    "/a.txt",
  );
  expect(opened).toBe(true);
  expect(calls).toEqual([["chat.changesPane", { session: "chat-1", row: "row-7", tool: "tool-3", path: "/a.txt" }]]);
  expect(await openChangesPane(async () => ({ opened: false }), "chat-1", "row-7", undefined)).toBe(false);
  expect(
    await openChangesPane(
      async () => {
        throw new Error("unsupported");
      },
      "chat-1",
      "row-7",
      undefined,
    ),
  ).toBe(false);
});

test("a turn counts as loaded only from an opener with no gap above its rows", async () => {
  const { turnStartLoaded } = await import("../src/agent-session/acpmux/diff");
  // The opener fetched on its own sits at the top, above a gap, while older history is left.
  expect(turnStartLoaded([prompt("p1"), activity("a9")], "a9", true)).toBe(false);
  // The chat's history is all here: the top is the chat's start.
  expect(turnStartLoaded([prompt("p1"), activity("a9")], "a9", false)).toBe(true);
  // An opener below other loaded rows has every row of its turn after it.
  expect(turnStartLoaded([activity("a0"), prompt("p1"), activity("a9")], "a9", true)).toBe(true);
  // A row whose opener is not loaded yet, or a row not loaded at all.
  expect(turnStartLoaded([activity("a8"), activity("a9")], "a9", true)).toBe(false);
  expect(turnStartLoaded([activity("a9")], "a7", false)).toBe(false);
});
