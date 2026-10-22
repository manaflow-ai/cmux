// A turn's changes in a pane of their own (turnChanges/changesPane.ts): the `changes:` reveal the
// app sends that pane names the turn's row and the file to show first, and the page asks the app
// for that pane with `chat.changesPane`, showing the changes in place when none opened.
import { expect, test } from "bun:test";
import { CHANGES_REVEAL, openChangesPane, revealedChanges } from "../src/agent-session/acpmux/turnChanges/changesPane";

test("a changes reveal names the chat, the row and the file", () => {
  expect(revealedChanges(`${CHANGES_REVEAL}chat-1\nrow-7\n/private/tmp/scratch/batch103.sh`)).toEqual({
    sessionId: "chat-1",
    rowId: "row-7",
    path: "/private/tmp/scratch/batch103.sh",
  });
  expect(revealedChanges(`${CHANGES_REVEAL}chat-1\nrow-7`)).toEqual({ sessionId: "chat-1", rowId: "row-7" });
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
    "/a.txt",
  );
  expect(opened).toBe(true);
  expect(calls).toEqual([["chat.changesPane", { session: "chat-1", row: "row-7", path: "/a.txt" }]]);
  expect(await openChangesPane(async () => ({ opened: false }), "chat-1", "row-7")).toBe(false);
  expect(
    await openChangesPane(
      async () => {
        throw new Error("unsupported");
      },
      "chat-1",
      "row-7",
    ),
  ).toBe(false);
});

test("a turn counts as loaded only from an opener with no gap above its rows", async () => {
  const { turnStartLoaded } = await import("../src/agent-session/acpmux/diff");
  const prompt = (id: string) => ({ id, version: 1, at: 0, kind: "user", text: "go" }) as never;
  const activity = (id: string) => ({ id, version: 1, at: 0, kind: "activity", items: [] }) as never;
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
