// l10n-allow-file: test fixture paths and file text, not shipped UI.
// A Write that failed with no content (its call keeps only the pending fragment acpmux sent, with
// no old text) stays on the edited-files card, marked "failed" where a row's counts go, as the
// transcript marks a failed call. It wrote nothing, so it neither counts nor hides a later edit to
// the same file: Claude Code's Write fails until the file is read, and the retry is the change.
//
// Before: the failed Write dropped off the card ("Edited 0 files" with no row), and an Edit after
// it to the same file lost its counts.
import { expect, test } from "bun:test";
import {
  NOTES,
  PLAN,
  activity,
  editWithDiff,
  editedCard,
  toolCall,
  translatorWrite,
  useDom,
} from "./support/unknownWrite";

const dom = useDom();

/// Each row's path and what sits at its right edge: its counts, or "failed".
const rows = () =>
  [...dom.host().querySelectorAll(".acpmux-edited-file")].map((entry) => [
    entry.querySelector(".acpmux-edited-path")?.getAttribute("data-path"),
    entry.querySelector(".acpmux-diff-counts, .acpmux-edited-failed")?.textContent,
  ]);

test("a failed Write with no content stays on the card, marked failed", async () => {
  await dom.render(await editedCard(activity("turn-f1", [await translatorWrite("write-1", NOTES, "failed")])));
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited 1 file");
  expect(rows()).toEqual([[NOTES, "failed"]]);
  expect(dom.host().querySelector(".acpmux-edited .acpmux-diff-add")).toBeNull();
  expect(dom.host().querySelector(".acpmux-edited-undo")).toBeNull();
});

test("beside a counted edit, the failed Write lists as failed", async () => {
  const row = activity("turn-f2", [
    await editWithDiff("edit-1", PLAN, "a\n", "b\n"),
    await translatorWrite("write-2", NOTES, "failed"),
  ]);
  await dom.render(await editedCard(row));
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited 2 files");
  expect(dom.text(".acpmux-edited-sub")).toBe("+1-1");
  expect(rows()).toEqual([
    [PLAN, "+1-1"],
    [NOTES, "failed"],
  ]);
});

test("an edit after the failed Write keeps its counts, and the file is not marked failed", async () => {
  const row = activity("turn-f3", [
    await translatorWrite("write-3", NOTES, "failed"),
    await editWithDiff("edit-2", NOTES, "step 1\n", "step one\n"),
  ]);
  await dom.render(await editedCard(row));
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited notes.txt");
  expect(dom.text(".acpmux-edited-sub")).toBe("+1-1");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("a retried Write of unknown old contents lists the file once, not failed", async () => {
  const row = activity("turn-f4", [
    await translatorWrite("write-4", NOTES, "failed"),
    await translatorWrite("write-5", NOTES, "updated"),
  ]);
  await dom.render(await editedCard(row));
  expect(rows()).toEqual([[NOTES, undefined]]);
});

test("a failed edit that carried no diff lists as failed too", async () => {
  const failedMove = await toolCall("move-1", [
    { title: "Move notes.txt", kind: "edit", status: "pending", locations: [{ path: NOTES }] },
    { status: "failed", content: [{ type: "content", content: { type: "text", text: "No such file" } }] },
  ]);
  await dom.render(await editedCard(activity("turn-f5", [failedMove])));
  expect(rows()).toEqual([[NOTES, "failed"]]);
});
