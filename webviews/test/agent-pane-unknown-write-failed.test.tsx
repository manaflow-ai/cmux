// l10n-allow-file: test fixture paths and file text, not shipped UI.
// A Write that failed with no content (its call keeps only the pending fragment acpmux sent, with
// no old text) stays on the edited-files card, marked "failed" where a row's counts go, as the
// transcript marks a failed call. It wrote nothing, so it neither counts nor hides a later edit to
// the same file: Claude Code's Write fails until the file is read, and the retry is the change.
//
// So it does once the turn's checkpoint has loaded: no checkpoint file covers a file a failed call
// named, wherever it is. A counted file whose path only ends the same way is another file (a
// monorepo's docs/notes.txt beside its notes.txt), so it hides no failed row.
//
// Before: the failed Write dropped off the card ("Edited 0 files" with no row), and an Edit after
// it to the same file lost its counts.
import { expect, test } from "bun:test";
import {
  FOLDER,
  NOTES,
  PLAN,
  activity,
  checkpoint,
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

test("once the checkpoint loads, a failed Write in the repository stays on the card", async () => {
  const row = activity("turn-f6", [await translatorWrite("write-6", NOTES, "failed")]);
  await dom.render(await editedCard(row, checkpoint()));
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited 1 file");
  expect(rows()).toEqual([[NOTES, "failed"]]);
});

test("once the checkpoint loads, a failed Write lists after the repository's counted files", async () => {
  const row = activity("turn-f7", [
    await editWithDiff("edit-3", PLAN, "a\n", "b\n"),
    await translatorWrite("write-7", NOTES, "failed"),
  ]);
  await dom.render(
    await editedCard(
      row,
      checkpoint([{ path: "plan.md", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b\n" }]),
    ),
  );
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited 2 files");
  expect(rows()).toEqual([
    [PLAN, "+1-1"],
    [NOTES, "failed"],
  ]);
});

test("once the checkpoint loads, a failed Write under a path alias of the repository lists no row of its own", async () => {
  // The agent wrote /tmp/repo/notes.txt; git names the repository by its real path, /private/tmp/repo.
  const path = "/tmp/repo/notes.txt";
  const row = activity("turn-f8", [
    await translatorWrite("write-8", path, "failed"),
    await editWithDiff("edit-4", path, "step 1\n", "step one\n"),
  ]);
  const load = checkpoint(
    [{ path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-step 1\n+step one\n" }],
    "/private/tmp/repo",
  );
  await dom.render(await editedCard(row, load));
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited notes.txt");
  expect(dom.text(".acpmux-edited-sub")).toBe("+1-1");
  expect(rows()).toEqual([]);
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("once the checkpoint loads, a failed Write deeper in the repository stays beside a counted file of its name", async () => {
  // A monorepo: the failed Write is docs/notes.txt, the counted edit the root's notes.txt.
  const nested = `${FOLDER}/docs/notes.txt`;
  const row = activity("turn-f9", [
    await translatorWrite("write-9", nested, "failed"),
    await editWithDiff("edit-5", NOTES, "step 1\n", "step one\n"),
  ]);
  await dom.render(
    await editedCard(
      row,
      checkpoint([{ path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-step 1\n+step one\n" }]),
    ),
  );
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited 2 files");
  expect(rows()).toEqual([
    [NOTES, "+1-1"],
    [nested, "failed"],
  ]);
});

test("once the checkpoint loads, a failed Write outside the repository stays beside a counted file of its name", async () => {
  const elsewhere = "/Users/you/notes/notes.txt";
  const row = activity("turn-f10", [
    await translatorWrite("write-10", elsewhere, "failed"),
    await editWithDiff("edit-6", NOTES, "step 1\n", "step one\n"),
  ]);
  await dom.render(
    await editedCard(
      row,
      checkpoint([{ path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-step 1\n+step one\n" }]),
    ),
  );
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited 2 files");
  expect(rows()).toEqual([
    [NOTES, "+1-1"],
    [elsewhere, "failed"],
  ]);
});

test("once the checkpoint loads, a failed Write the agent named from ~ lists no row beside the edit that followed", async () => {
  const path = "~/src/uploader/notes.txt";
  const row = activity("turn-f11", [
    await translatorWrite("write-11", path, "failed"),
    await editWithDiff("edit-7", path, "step 1\n", "step one\n"),
  ]);
  await dom.render(
    await editedCard(
      row,
      checkpoint([{ path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-step 1\n+step one\n" }]),
    ),
  );
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited notes.txt");
  expect(rows()).toEqual([]);
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("once the checkpoint loads, a failed Write retried through a folder link the repository's name doesn't match lists once", async () => {
  // The agent works in a link (~/work/current) to the repository git names by its real path, so only
  // the later Edit's suffix match ties the path to the checkpoint's notes.txt.
  const path = "/Users/you/work/current/notes.txt";
  const row = activity("turn-f12", [
    await translatorWrite("write-12", path, "failed"),
    await editWithDiff("edit-8", path, "step 1\n", "step one\n"),
  ]);
  await dom.render(
    await editedCard(
      row,
      checkpoint([{ path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-step 1\n+step one\n" }]),
    ),
  );
  expect(dom.text(".acpmux-edited-title > div")).toBe("Edited notes.txt");
  expect(rows()).toEqual([]);
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("once the checkpoint loads, a failed Write in the repository stays beside an edited file of its name outside it", async () => {
  const outside = "/tmp/scratch/notes.txt";
  const row = activity("turn-f13", [
    await translatorWrite("write-13", NOTES, "failed"),
    await editWithDiff("edit-9", PLAN, "a\n", "b\n"),
    await editWithDiff("edit-10", outside, "step 1\n", "step one\n"),
  ]);
  await dom.render(
    await editedCard(
      row,
      checkpoint([{ path: "plan.md", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b\n" }]),
    ),
  );
  expect(rows()).toContainEqual([NOTES, "failed"]);
});
