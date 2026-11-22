import { expect, test } from "bun:test";
import {
  defaultDiffFileFilter,
  diffFileStatus,
  filterDiffItems,
  isDiffFileFilterActive,
  matchesPathQuery,
  toggleStatusFilter,
} from "../src/file-filter";

const items = [
  { id: "src/app.ts", fileDiff: { name: "src/app.ts", type: "change", hunks: [] } },
  { id: "src/new.ts", fileDiff: { name: "src/new.ts", type: "new", hunks: [] } },
  { id: "docs/old.md", fileDiff: { name: "docs/old.md", type: "deleted", hunks: [] } },
  { id: "src/moved.ts", fileDiff: { name: "src/moved.ts", prevName: "src/old.ts", type: "rename-changed", hunks: [] } },
];

test("diffFileStatus maps Pierre change types onto the four review statuses", () => {
  expect(diffFileStatus({ type: "change" })).toBe("modified");
  expect(diffFileStatus({ type: "new" })).toBe("added");
  expect(diffFileStatus({ type: "deleted" })).toBe("deleted");
  expect(diffFileStatus({ type: "rename-pure" })).toBe("renamed");
  expect(diffFileStatus({ type: "rename-changed" })).toBe("renamed");
  expect(diffFileStatus({})).toBe("modified");
});

test("matchesPathQuery is a case-insensitive substring match per whitespace term", () => {
  expect(matchesPathQuery("src/App.tsx", "")).toBe(true);
  expect(matchesPathQuery("src/App.tsx", "app")).toBe(true);
  expect(matchesPathQuery("src/App.tsx", "src tsx")).toBe(true);
  expect(matchesPathQuery("src/App.tsx", "docs")).toBe(false);
  expect(matchesPathQuery("src/App.tsx", "app docs")).toBe(false);
});

test("filterDiffItems applies the path query, status toggles, and hide-viewed together", () => {
  const filter = defaultDiffFileFilter();
  expect(isDiffFileFilterActive(filter)).toBe(false);
  const unviewed = () => "unviewed" as const;
  expect(filterDiffItems(items, filter, unviewed)).toEqual(items);

  expect(filterDiffItems(items, { ...filter, query: "src" }, unviewed).map((item) => item.id)).toEqual([
    "src/app.ts",
    "src/new.ts",
    "src/moved.ts",
  ]);
  // A renamed file matches on its previous path too.
  expect(filterDiffItems(items, { ...filter, query: "old.ts" }, unviewed).map((item) => item.id)).toEqual([
    "src/moved.ts",
  ]);

  const addedOnly = { ...filter, statuses: ["added" as const] };
  expect(isDiffFileFilterActive(addedOnly)).toBe(true);
  expect(filterDiffItems(items, addedOnly, unviewed).map((item) => item.id)).toEqual(["src/new.ts"]);

  const viewedState = (item: { id: string }) =>
    item.id === "src/app.ts" ? ("viewed" as const) : ("unviewed" as const);
  expect(filterDiffItems(items, { ...filter, hideViewed: true }, viewedState).map((item) => item.id)).toEqual([
    "src/new.ts",
    "docs/old.md",
    "src/moved.ts",
  ]);
  // A file whose patch changed since it was viewed is not hidden.
  const changedState = (item: { id: string }) =>
    item.id === "src/app.ts" ? ("changed" as const) : ("unviewed" as const);
  expect(filterDiffItems(items, { ...filter, hideViewed: true }, changedState)).toHaveLength(4);
});

test("toggleStatusFilter flips one status and never empties the set", () => {
  const all = defaultDiffFileFilter().statuses;
  expect(toggleStatusFilter(all, "added")).toEqual(["modified", "deleted", "renamed"]);
  expect(toggleStatusFilter(["added"], "added")).toEqual(["added", "modified", "deleted", "renamed"]);
  expect(toggleStatusFilter(["added"], "deleted")).toEqual(["added", "deleted"]);
});
