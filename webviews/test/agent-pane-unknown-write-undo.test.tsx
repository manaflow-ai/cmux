// l10n-allow-file: test fixture paths and file text, not shipped UI.
// The edited-files card's Undo confirmation names the files Undo leaves as they are: those listed
// without counts, such as a Write whose old contents are unknown, which no Undo can restore. The
// host is never asked about them; a file only a failed Write named changed nothing and is not named.
//
// Before: the confirmation said "Undo 1 file?" and nothing about notes.txt, which the card lists
// beside it, so a reader could take Undo to restore the whole turn.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { NOTES, PLAN, SETUP, activity, editedCard, translatorWrite, useDom } from "./support/unknownWrite";

const dom = useDom();
let asked: string[][] = [];

afterEach(async () => {
  const { setUndoCall } = await import("../src/agent-session/acpmux/turnChanges/undoStore");
  const { postNative } = await import("../src/agent-session/acpmux/native");
  setUndoCall((files, apply) => postNative("turn.undo", { files, apply }));
  asked = [];
});

/// The card for `row`, its Undo clicked, with the host's dry run saying it would trash every file.
async function confirmUndo(row: ReturnType<typeof activity>) {
  const { setUndoCall } = await import("../src/agent-session/acpmux/turnChanges/undoStore");
  setUndoCall(async (files) => {
    asked.push(files.map((file) => file.path));
    return { files: files.map((file) => ({ path: file.path, status: "wouldTrash" })) };
  });
  await dom.render(await editedCard(row));
  await dom.click(dom.host().querySelector(".acpmux-edited-undo"));
  // The dry run answers after the click's own update.
  await act(async () => {});
  expect(dom.host().querySelector(".acpmux-edited-confirm")).not.toBeNull();
}

test("the confirmation names a Write of unknown old contents as skipped", async () => {
  await confirmUndo(
    activity("turn-undo-1", [
      await translatorWrite("write-1", SETUP, "created"),
      await translatorWrite("write-2", NOTES, "updated"),
    ]),
  );
  expect(asked).toEqual([[SETUP]]);
  expect(dom.text(".acpmux-edited-confirm-kept")).toBe(
    "notes.txt will be skipped: its contents before this turn are unknown.",
  );
});

test("two such Writes are named in one list", async () => {
  await confirmUndo(
    activity("turn-undo-2", [
      await translatorWrite("write-3", SETUP, "created"),
      await translatorWrite("write-4", NOTES, "updated"),
      await translatorWrite("write-5", PLAN, "updated"),
    ]),
  );
  expect(dom.text(".acpmux-edited-confirm-kept")).toBe(
    "These files will be skipped, since their contents before this turn are unknown: notes.txt and plan.md.",
  );
});

test("a file only a failed Write named is not in the confirmation", async () => {
  await confirmUndo(
    activity("turn-undo-3", [
      await translatorWrite("write-6", SETUP, "created"),
      await translatorWrite("write-7", NOTES, "failed"),
    ]),
  );
  expect(dom.host().querySelector(".acpmux-edited-confirm-kept")).toBeNull();
});
