// The GitHub page's condensed checks and per-file bars (Leo, 2026-11-07: "do you really need to
// see the greens? You mostly just want to see the reds"): failing and running first, passed apart.
import { expect, test } from "bun:test";
import { fileCells, groupChecks } from "./GitHubPage";
import { openableLink } from "./GitHubMarkdown";

test("checks group as failing, running, then passed", () => {
  const groups = groupChecks([
    { name: "a", state: "passed" },
    { name: "b", state: "failed" },
    { name: "c", state: "pending" },
    { name: "d", state: "passed" },
    { name: "e", state: "failed" },
  ]);
  expect(groups.failed.map((check) => check.name)).toEqual(["b", "e"]);
  expect(groups.pending.map((check) => check.name)).toEqual(["c"]);
  expect(groups.passed.map((check) => check.name)).toEqual(["a", "d"]);
});

test("a file's five cells split added and removed; a small change fills fewer", () => {
  expect(fileCells(120, 22)).toEqual(["add", "add", "add", "add", "del"]);
  expect(fileCells(0, 7)).toEqual(["del", "del", "del", "del", "del"]);
  expect(fileCells(1, 1)).toEqual(["add", "del", "none", "none", "none"]);
  expect(fileCells(0, 0)).toEqual(["none", "none", "none", "none", "none"]);
});

test("a body's link opens only when it is absolute https", () => {
  expect(openableLink("https://github.com/a/b/issues/1")).toBe("https://github.com/a/b/issues/1");
  expect(openableLink("javascript:alert(1)")).toBeUndefined();
  expect(openableLink("http://example.com")).toBeUndefined();
  expect(openableLink("/relative")).toBeUndefined();
});
