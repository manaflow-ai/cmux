// l10n-allow-file: test fixture paths and file text, not shipped UI.
// The edited-files card's Undo confirmation names the files Undo leaves as they are: those the page
// has no old text for, such as a Write whose old contents are unknown. The host is never asked about
// them; a file only a failed Write named changed nothing and is not named. The words hold once the
// turn's checkpoint has loaded too, when the card shows the checkpoint's counts for such a file.
// Two files of one name are named from their shared directory, as the card's rows are.
//
// Before: the confirmation said "Undo 1 file?" and nothing about notes.txt, which the card lists
// beside it, so a reader could take Undo to restore the whole turn.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import {
  FOLDER,
  NOTES,
  PLAN,
  SETUP,
  activity,
  checkpoint,
  editedCard,
  translatorWrite,
  useDom,
} from "./support/unknownWrite";
import type { TurnCheckpointLoad } from "../src/agent-session/acpmux/changes/turnCheckpoint";

const dom = useDom();
let asked: string[][] = [];

afterEach(async () => {
  const { setUndoCall } = await import("../src/agent-session/acpmux/turnChanges/undoStore");
  const { postNative } = await import("../src/agent-session/acpmux/native");
  setUndoCall((files, apply) => postNative("turn.undo", { files, apply }));
  asked = [];
});

/// The card for `row`, its Undo clicked, with the host's dry run saying it would trash every file.
async function confirmUndo(row: ReturnType<typeof activity>, load?: TurnCheckpointLoad) {
  const { setUndoCall } = await import("../src/agent-session/acpmux/turnChanges/undoStore");
  setUndoCall(async (files) => {
    asked.push(files.map((file) => file.path));
    return { files: files.map((file) => ({ path: file.path, status: "wouldTrash" })) };
  });
  await dom.render(await editedCard(row, load));
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
  expect(dom.text(".acpmux-edited-confirm-kept")).toBe("Undo can't restore notes.txt.");
});

test("two such Writes are named in one list", async () => {
  await confirmUndo(
    activity("turn-undo-2", [
      await translatorWrite("write-3", SETUP, "created"),
      await translatorWrite("write-4", NOTES, "updated"),
      await translatorWrite("write-5", PLAN, "updated"),
    ]),
  );
  expect(dom.text(".acpmux-edited-confirm-kept")).toBe("Undo can't restore notes.txt and plan.md.");
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

test("two files of one name are named from their shared directory", async () => {
  await confirmUndo(
    activity("turn-undo-4", [
      await translatorWrite("write-8", SETUP, "created"),
      await translatorWrite("write-9", NOTES, "updated"),
      await translatorWrite("write-10", `${FOLDER}/docs/notes.txt`, "updated"),
    ]),
  );
  expect(dom.text(".acpmux-edited-confirm-kept")).toBe("Undo can't restore notes.txt and docs/notes.txt.");
});

test("once the checkpoint gives the file counts, the confirmation still says Undo can't restore it", async () => {
  const load = checkpoint([{ path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new\n" }]);
  await confirmUndo(
    activity("turn-undo-5", [
      await translatorWrite("write-11", SETUP, "created"),
      await translatorWrite("write-12", NOTES, "updated"),
    ]),
    load,
  );
  const notes = dom.host().querySelector(`.acpmux-edited-path[data-path="${NOTES}"]`)?.closest(".acpmux-edited-file");
  expect(notes?.querySelector(".acpmux-diff-counts")?.textContent).toBe("+1-1");
  expect(asked).toEqual([[SETUP]]);
  expect(dom.text(".acpmux-edited-confirm-kept")).toBe("Undo can't restore notes.txt.");
});
