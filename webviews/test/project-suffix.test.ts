// The folder popover names each project, and only an ambiguous name gets a short suffix that
// tells it apart (hq#1957 composer location strip): Leo's popover listed /Users/leoli/wt/... paths
// under several rows all named "cmux". The rule (projectSuffix.ts): projects sharing a name, case
// aside, each take the fewest trailing folders of their path (the name's own folder left out when
// it is the name) that no other project of that name shares at the same depth; the home folder
// reads ~, and a path with nothing left to tell it apart falls back to its parent folder.
import { expect, test } from "bun:test";
import { projectSuffixes } from "../src/agent-session/acpmux/projectSuffix";

const p = (cwd: string, label = cwd.split("/").filter(Boolean).at(-1)!) => ({ cwd, label });

test("a unique name gets no suffix", () => {
  const suffixes = projectSuffixes([p("/Users/leoli/src/atlas-web"), p("/Users/leoli/src/relay")]);
  expect(suffixes.size).toBe(0);
});

test("worktrees of one repo are told apart by their lane", () => {
  const suffixes = projectSuffixes([
    p("/Users/leoli/wt/lanes/cg-lane-adopt/cmux"),
    p("/Users/leoli/wt/lanes/fleet-ci/cmux"),
    p("/Users/leoli/src/atlas-web"),
  ]);
  expect(Object.fromEntries(suffixes)).toEqual({
    "/Users/leoli/wt/lanes/cg-lane-adopt/cmux": "cg-lane-adopt",
    "/Users/leoli/wt/lanes/fleet-ci/cmux": "fleet-ci",
  });
});

test("a worktree named for its branch, labeled by its repo, shows lane and folder", () => {
  // The host names a worktree by its repo ("cmux") while its folder is the branch's.
  const suffixes = projectSuffixes([
    p("/Users/leoli/wt/cg-lane-adopt/composer", "cmux"),
    p("/Users/leoli/wt/other-lane/composer", "cmux"),
    p("/Users/leoli/wt/cg-lane-adopt/composer-strip", "cmux"),
  ]);
  expect(Object.fromEntries(suffixes)).toEqual({
    "/Users/leoli/wt/cg-lane-adopt/composer": "cg-lane-adopt/composer",
    "/Users/leoli/wt/other-lane/composer": "other-lane/composer",
    "/Users/leoli/wt/cg-lane-adopt/composer-strip": "composer-strip",
  });
});

test("the checkout in the home folder reads ~", () => {
  const suffixes = projectSuffixes([p("/Users/leoli/cmux"), p("/Users/leoli/wt/lanes/a/cmux")]);
  expect(Object.fromEntries(suffixes)).toEqual({ "/Users/leoli/cmux": "~", "/Users/leoli/wt/lanes/a/cmux": "a" });
});

test("a shared parent name goes one folder deeper", () => {
  const suffixes = projectSuffixes([p("/Users/leoli/one/src/cmux"), p("/Users/leoli/two/src/cmux")]);
  expect(Object.fromEntries(suffixes)).toEqual({
    "/Users/leoli/one/src/cmux": "one/src",
    "/Users/leoli/two/src/cmux": "two/src",
  });
});

test("a path that ends where another's tail begins falls back to its parent folder", () => {
  const suffixes = projectSuffixes([p("/src/cmux"), p("/Users/leoli/src/cmux")]);
  expect(Object.fromEntries(suffixes)).toEqual({ "/src/cmux": "/src", "/Users/leoli/src/cmux": "~/src" });
});

test("names match case aside, trailing slashes and repeats count once", () => {
  const suffixes = projectSuffixes([
    p("/Users/leoli/a/cmux/"),
    p("/Users/leoli/a/cmux"),
    p("/Users/leoli/b/CMUX", "CMUX"),
  ]);
  expect(Object.fromEntries(suffixes)).toEqual({
    "/Users/leoli/a/cmux/": "a",
    "/Users/leoli/a/cmux": "a",
    "/Users/leoli/b/CMUX": "b",
  });
});

test("Linux home folders read ~ too", () => {
  const suffixes = projectSuffixes([p("/home/dev/cmux"), p("/home/dev/work/cmux")]);
  expect(Object.fromEntries(suffixes)).toEqual({ "/home/dev/cmux": "~", "/home/dev/work/cmux": "work" });
});
