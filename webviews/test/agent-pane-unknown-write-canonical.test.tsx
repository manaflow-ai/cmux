// l10n-allow-file: test fixture paths and file text, not shipped UI.
// A failed call and its retry that name one file in two spellings list it once on the edited-files
// card: a folder link and the real path, `./notes.txt` and the absolute path, or another letter case
// on a case-insensitive volume. acpmux records each tool call path's canonical form beside the
// agent's (`_meta.acpmux.canonicalPath`, hub `path_canon`), and the card compares only those, with
// one another and with the turn checkpoint's `${root}/${path}`. Rows still show, open and undo the
// agent's own spelling.
//
// Before: the failed Write listed as "failed" beside the counted retry, because the paths differ as
// written. Matching by path suffix hid some of these and wrongly tied a monorepo's docs/notes.txt to
// its notes.txt. Without a canonical path (an older log or peer) the card falls back to that match.
import { expect, test } from "bun:test";
import {
  FOLDER,
  NOTES,
  activity,
  checkpoint,
  editWithDiff,
  editedCard,
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
const title = () => dom.text(".acpmux-edited-title > div");

/// The agent's folder link to the repository at FOLDER.
const LINK = "/Users/you/work/current/notes.txt";
const notesPatch = { path: "notes.txt", additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-step 1\n+step one\n" };

test("a failed Write through a folder link, retried at the real path, lists once", async () => {
  const row = activity("turn-c1", [
    await translatorWrite("write-c1", LINK, "failed", NOTES),
    await editWithDiff("edit-c1", NOTES, "step 1\n", "step one\n", NOTES),
  ]);
  await dom.render(await editedCard(row));
  expect(title()).toBe("Edited notes.txt");
  expect(dom.text(".acpmux-edited-sub")).toBe("+1-1");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("once the checkpoint loads, a failed Write through a folder link, retried at the real path, lists once", async () => {
  const row = activity("turn-c2", [
    await translatorWrite("write-c2", LINK, "failed", NOTES),
    await editWithDiff("edit-c2", NOTES, "step 1\n", "step one\n", NOTES),
  ]);
  await dom.render(await editedCard(row, checkpoint([notesPatch])));
  expect(title()).toBe("Edited notes.txt");
  expect(rows()).toEqual([]);
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

/// A failed Write at `spelling` (canonical NOTES), then an Edit at NOTES.
const retried = async (id: string, spelling: string) =>
  activity(id, [
    await translatorWrite(`write-${id}`, spelling, "failed", NOTES),
    await editWithDiff(`edit-${id}`, NOTES, "step 1\n", "step one\n", NOTES),
  ]);

test("a failed Write at ./notes.txt, retried at the absolute path, lists once", async () => {
  await dom.render(await editedCard(await retried("turn-c3", "./notes.txt")));
  expect(title()).toBe("Edited notes.txt");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("once the checkpoint loads, a failed Write at ./notes.txt, retried at the absolute path, lists once", async () => {
  await dom.render(await editedCard(await retried("turn-c4", "./notes.txt"), checkpoint([notesPatch])));
  expect(title()).toBe("Edited notes.txt");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("a failed Write in another letter case, retried as the file is spelled, lists once", async () => {
  await dom.render(await editedCard(await retried("turn-c5", `${FOLDER}/Notes.txt`)));
  expect(title()).toBe("Edited notes.txt");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("once the checkpoint loads, a failed Write in another letter case, retried as the file is spelled, lists once", async () => {
  await dom.render(await editedCard(await retried("turn-c6", `${FOLDER}/Notes.txt`), checkpoint([notesPatch])));
  expect(title()).toBe("Edited notes.txt");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
});

test("an edit at a folder link keeps the agent's spelling on its row", async () => {
  const row = activity("turn-c7", [
    await editWithDiff("edit-c7", LINK, "step 1\n", "step one\n", NOTES),
    await editWithDiff("edit-c7b", `${FOLDER}/plan.md`, "a\n", "b\n", `${FOLDER}/plan.md`),
  ]);
  await dom.render(await editedCard(row));
  expect(rows()).toEqual([
    [LINK, "+1-1"],
    [`${FOLDER}/plan.md`, "+1-1"],
  ]);
});

test("once the checkpoint loads, a repository file only a deeper file of its name was edited at reads as changed outside the tools", async () => {
  // A monorepo: the agent edited docs/notes.txt; a formatter also changed the root's notes.txt.
  const nested = `${FOLDER}/docs/notes.txt`;
  const row = activity("turn-c8", [await editWithDiff("edit-c8", nested, "step 1\n", "step one\n", nested)]);
  await dom.render(await editedCard(row, checkpoint([{ ...notesPatch, path: "docs/notes.txt" }, notesPatch])));
  expect(title()).toBe("Edited 2 files");
  expect(dom.host().querySelector(".acpmux-edited-outside")).not.toBeNull();
});

test("once the checkpoint loads, a failed Write in the repository stays beside the one edited file outside it", async () => {
  // namesCheckpointFile's own guard: the file outside the repository is the turn's only tool file, so
  // its displayed path is notes.txt, which the failed Write's path from the root also is. Only the
  // guard (an outside file is only its own path) keeps the failed row.
  const outside = "/tmp/scratch/notes.txt";
  const row = activity("turn-c9", [
    await translatorWrite("write-c9", NOTES, "failed"),
    await editWithDiff("edit-c9", outside, "step 1\n", "step one\n"),
  ]);
  await dom.render(await editedCard(row, checkpoint()));
  expect(rows()).toEqual([
    [outside, "+1-1"],
    [NOTES, "failed"],
  ]);
});

test("with canonical paths, a failed Write in the repository stays beside the one edited file outside it", async () => {
  const outside = "/tmp/scratch/notes.txt";
  const row = activity("turn-c10", [
    await translatorWrite("write-c10", NOTES, "failed", NOTES),
    await editWithDiff("edit-c10", outside, "step 1\n", "step one\n", "/private/tmp/scratch/notes.txt"),
  ]);
  await dom.render(await editedCard(row, checkpoint()));
  expect(rows()).toEqual([
    [outside, "+1-1"],
    [NOTES, "failed"],
  ]);
});

test("without canonical paths, a failed Write through a folder link lists beside its retry at the real path", async () => {
  // An older log or peer: nothing ties the two spellings, so the card lists both, as before.
  const row = activity("turn-c11", [
    await translatorWrite("write-c11", LINK, "failed"),
    await editWithDiff("edit-c11", NOTES, "step 1\n", "step one\n"),
  ]);
  await dom.render(await editedCard(row));
  expect(rows()).toEqual([
    [NOTES, "+1-1"],
    [LINK, "failed"],
  ]);
});

test("once the checkpoint loads, a repository whose folder git names decomposed still holds the edited file", async () => {
  // git prints a folder created as `Cafe\u0301` as stored, decomposed; acpmux's canonical paths are
  // composed (NFC). They are one folder.
  const composed = "/Users/you/src/Caf\u00e9/notes.txt";
  const row = activity("turn-c12", [
    await translatorWrite("write-c12", composed, "failed", composed),
    await editWithDiff("edit-c12", composed, "step 1\n", "step one\n", composed),
  ]);
  await dom.render(await editedCard(row, checkpoint([notesPatch], "/Users/you/src/Cafe\u0301")));
  expect(title()).toBe("Edited notes.txt");
  expect(dom.host().querySelector(".acpmux-edited-failed")).toBeNull();
  expect(dom.host().querySelector(".acpmux-edited-outside")).toBeNull();
});

test("a file edited at ./ and then at its absolute path undoes, by the absolute path, to before both", async () => {
  const absolute = `${FOLDER}/x.txt`;
  const row = activity("turn-c13", [
    await editWithDiff("edit-c13a", "./x.txt", "a\n", "b\n", absolute),
    await editWithDiff("edit-c13b", absolute, "b\n", "c\n", absolute),
  ]);
  const { turnChanges } = await import("../src/agent-session/acpmux/turnChanges/model");
  const { turnFiles } = await import("../src/agent-session/acpmux/diff");
  const files = turnChanges(row.id, [row], turnFiles([row])).files;
  expect(files.map(({ path, undo }) => ({ path, undo }))).toEqual([
    { path: absolute, undo: { kind: "revert", before: "a\n", after: "c\n" } },
  ]);
  await dom.render(await editedCard(row));
  expect(dom.host().querySelector(".acpmux-edited-undo")).not.toBeNull();
});

test("an output opens at the last turn that changed it, whichever spelling that turn used", async () => {
  const absolute = `${FOLDER}/x.txt`;
  const prompt = (id: string) => ({ id, version: 1, at: 1, kind: "user" as const, text: "go" });
  const rows = [
    prompt("prompt-1"),
    activity("turn-c14a", [await editWithDiff("edit-c14a", "./x.txt", "a\n", "b\n", absolute)]),
    prompt("prompt-2"),
    activity("turn-c14b", [await editWithDiff("edit-c14b", absolute, "b\n", "c\n", absolute)]),
  ];
  const { lastChange } = await import("../src/agent-session/acpmux/diff");
  expect(lastChange(rows, "./x.txt")).toEqual({ rowId: "turn-c14b", path: absolute });
  expect(lastChange(rows, `${FOLDER}/other.txt`)).toBeUndefined();
});
