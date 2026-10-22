// A turn's changes in a pane of their own (turnChanges/changesPane.ts): the `changes:` reveal the
// app sends that pane names the turn's row and the file to show first, and the page asks the app
// for that pane with `chat.changesPane`, showing the changes in place when none opened.
import { expect, test } from "bun:test";
import { CHANGES_REVEAL, openChangesPane, revealedChanges } from "../src/agent-session/acpmux/turnChanges/changesPane";

test("a changes reveal names the row and the file", () => {
  expect(revealedChanges(`${CHANGES_REVEAL}row-7\n/private/tmp/scratch/batch103.sh`)).toEqual({
    rowId: "row-7",
    path: "/private/tmp/scratch/batch103.sh",
  });
  expect(revealedChanges(`${CHANGES_REVEAL}row-7`)).toEqual({ rowId: "row-7" });
});

test("other reveals and an empty row are not changes", () => {
  expect(revealedChanges("turn-12")).toBeUndefined();
  expect(revealedChanges("subagent:abc")).toBeUndefined();
  expect(revealedChanges(CHANGES_REVEAL)).toBeUndefined();
  expect(revealedChanges(`${CHANGES_REVEAL}\n/a.txt`)).toBeUndefined();
});

test("the page asks for the pane and reads whether one opened", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const opened = await openChangesPane(
    async (method, params) => {
      calls.push([method, params]);
      return { opened: true };
    },
    "row-7",
    "/a.txt",
  );
  expect(opened).toBe(true);
  expect(calls).toEqual([["chat.changesPane", { row: "row-7", path: "/a.txt" }]]);
  expect(await openChangesPane(async () => ({ opened: false }), "row-7")).toBe(false);
  expect(
    await openChangesPane(async () => {
      throw new Error("unsupported");
    }, "row-7"),
  ).toBe(false);
});
