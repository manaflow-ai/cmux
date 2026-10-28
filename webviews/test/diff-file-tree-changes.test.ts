// The diff tab's files tree says each file's change, as a pull request's file tree does: after the
// "+N -N" counts, a square plus (added, green), a square minus (deleted, red) or a square dot
// (edited or renamed, blue). Names take the same colors: green, red and blue.
import { expect, test } from "bun:test";
import {
  diffChangeSpriteSheet,
  diffChangeSymbolId,
  diffFileChangeOf,
  fileTreeChangeDecoration,
  nameColoredGitStatus,
} from "../src/file-tree-stats";

const measure = (text: string) => text.length * 7;
const titles = (change: string) => ({ additions: "Additions", deletions: "Deletions", change });

test("the tree's git statuses map to a change; anything unknown is an edit", () => {
  expect(diffFileChangeOf("added")).toBe("added");
  expect(diffFileChangeOf("deleted")).toBe("deleted");
  expect(diffFileChangeOf("renamed")).toBe("renamed");
  expect(diffFileChangeOf("modified")).toBe("modified");
  expect(diffFileChangeOf(undefined)).toBe("modified");
});

test("added, deleted, modified and renamed files color their names", () => {
  expect(
    nameColoredGitStatus([
      { path: "a.txt", status: "added" },
      { path: "b.txt", status: "modified" },
      { path: "c.txt", status: "deleted" },
      { path: "d.txt", status: "renamed" },
    ]),
  ).toEqual([
    { path: "a.txt", status: "added" },
    { path: "b.txt", status: "modified" },
    { path: "c.txt", status: "deleted" },
    { path: "d.txt", status: "renamed" },
  ]);
});

test("a file the stream gave no status is modified, so it is blue too", () => {
  // The stream records only added, deleted and renamed files; every other listed file is modified.
  expect(nameColoredGitStatus([{ path: "new.txt", status: "added" }], ["new.txt", "edited.ts", "src/b.ts"])).toEqual([
    { path: "new.txt", status: "added" },
    { path: "edited.ts", status: "modified" },
    { path: "src/b.ts", status: "modified" },
  ]);
});

test("each change draws its own square in its own color, after the counts", () => {
  const sheet = diffChangeSpriteSheet(
    [
      { change: "added", stats: { added: 3, deleted: 0 } },
      { change: "deleted", stats: { added: 0, deleted: 2 } },
      { change: "modified", stats: { added: 1, deleted: 1 } },
      { change: "renamed", stats: undefined },
    ],
    measure,
  );
  const symbol = (id: string) => sheet.match(new RegExp(`<symbol id="${id}"[^]*?</symbol>`))?.[0] ?? "";

  const added = symbol(diffChangeSymbolId("added", { added: 3, deleted: 0 }));
  expect(added).toContain(">+3<");
  expect(added).toContain('stroke="var(--trees-status-added)"');
  expect(added).toMatch(/<path d="M[\d.]+ [\d.]+v5\.5M[\d.]+ [\d.]+h5\.5"\/>/);

  const deleted = symbol(diffChangeSymbolId("deleted", { added: 0, deleted: 2 }));
  expect(deleted).toContain(">-2<");
  expect(deleted).toContain('stroke="var(--trees-status-deleted)"');
  expect(deleted).toMatch(/<path d="M[\d.]+ [\d.]+h5\.5"\/>/);
  expect(deleted).not.toContain("v5.5");

  const edited = symbol(diffChangeSymbolId("modified", { added: 1, deleted: 1 }));
  expect(edited).toContain('stroke="var(--cmux-tree-modified)"');
  expect(edited).toContain("<circle");

  // A file with no counts (a pure rename, a binary file) still gets its square, and only that.
  const renamed = symbol(diffChangeSymbolId("renamed", undefined));
  expect(renamed).toContain('viewBox="0 0 12 16"');
  expect(renamed).not.toContain("<text");
  expect(renamed).toContain("<circle");
});

test("the decoration's title names the change, then the counts", () => {
  const decoration = fileTreeChangeDecoration("added", { added: 3, deleted: 0 }, titles("Added"), measure);
  expect(decoration.title).toBe("Added, Additions 3");
  expect(decoration.icon.name).toBe(diffChangeSymbolId("added", { added: 3, deleted: 0 }));
  // The counts, the gap and the 12 px square.
  expect(decoration.icon.width).toBeGreaterThan(12 + 5);
  const bare = fileTreeChangeDecoration("renamed", undefined, titles("Renamed"), measure);
  expect(bare.title).toBe("Renamed");
  expect(bare.icon.width).toBe(12);
});
