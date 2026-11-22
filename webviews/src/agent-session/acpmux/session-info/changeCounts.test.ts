import { expect, test } from "bun:test";
import { countsOf, readChangeCounts } from "./changeCounts";

test("a git.diff reply's totals, or none when it changes nothing", () => {
  expect(countsOf({ additions: 12, deletions: 3, files: [] })).toEqual({ additions: 12, deletions: 3 });
  expect(countsOf({ additions: 0, deletions: 0, files: [] })).toBeUndefined();
  expect(countsOf(undefined)).toBeUndefined();
  expect(countsOf({ additions: "7" })).toBeUndefined();
});

test("uncommitted work wins; a clean tree falls back to the branch's own commits", async () => {
  const asked: string[] = [];
  const reply = (uncommitted: unknown, branch: unknown) => (scope: "uncommitted" | "branch") => {
    asked.push(scope);
    return scope === "uncommitted" ? Promise.resolve(uncommitted) : Promise.resolve(branch);
  };
  expect(await readChangeCounts(reply({ additions: 2, deletions: 1 }, { additions: 9, deletions: 0 }))).toEqual({
    additions: 2,
    deletions: 1,
  });
  expect(asked).toEqual(["uncommitted"]);
  // An agent that committed its file: nothing uncommitted, the branch carries it.
  expect(await readChangeCounts(reply({ additions: 0, deletions: 0 }, { additions: 1, deletions: 0 }))).toEqual({
    additions: 1,
    deletions: 0,
  });
  // No repository, or a read that fails: no row.
  const fails = () => Promise.reject(new Error("Not a git repository"));
  expect(await readChangeCounts(fails)).toBeUndefined();
});
