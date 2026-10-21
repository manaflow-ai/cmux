// The project pickers fold a repository's worktrees under one row (projectRepos.ts): Austin's list
// showed each cmux worktree as a project of its own.
import { expect, test } from "bun:test";
import {
  belowCheckout,
  groupByRepo,
  guessProjectRepo,
  isMainCheckout,
  parseProjectRepos,
  shownRepoRows,
  worktreeName,
  type RepoFolder,
} from "./projectRepos";

const cmux = (branch: string) => ({ root: "/Users/me/src/cmux", name: "cmux", branch });
const lane = (name: string): RepoFolder => ({
  id: `/Users/me/.cmux/worktrees/cmux/${name}`,
  label: name,
  repo: cmux(name),
});
const folders: RepoFolder[] = [
  lane("issue-22273-runaway-children"),
  { id: "/Users/me/src/atlas", label: "atlas", repo: { root: "/Users/me/src/atlas", name: "atlas", branch: "main" } },
  lane("unread-ring-classic"),
  { id: "/Users/me/src/cmux", label: "cmux", repo: cmux("main") },
  lane("agent-caller-scoped"),
  { id: "/Users/me/notes", label: "notes" },
];

test("worktrees fold under their repository, which sits where its newest folder was", () => {
  const groups = groupByRepo(folders);
  expect(groups.map((group) => group.name)).toEqual(["cmux", "atlas", "notes"]);
  const [repo] = groups;
  expect(repo!.members.map((member) => member.label)).toEqual([
    "issue-22273-runaway-children",
    "unread-ring-classic",
    "cmux",
    "agent-caller-scoped",
  ]);
  // The row picks the main checkout, unless the current folder is one of the repository's.
  expect(repo!.lead.id).toBe("/Users/me/src/cmux");
  expect(groupByRepo(folders, lane("unread-ring-classic").id)[0]!.lead.label).toBe("unread-ring-classic");
});

test("with no main checkout listed, the newest worktree leads", () => {
  const groups = groupByRepo(folders.filter((folder) => folder.id !== "/Users/me/src/cmux"));
  expect(groups[0]!.lead.label).toBe("issue-22273-runaway-children");
});

test("an older host's folders fold by the usual worktree homes, with a same-named checkout", () => {
  const bare = folders.map(({ repo: _repo, ...folder }) => folder);
  const groups = groupByRepo(bare);
  expect(groups.map((group) => [group.name, group.members.length])).toEqual([
    ["cmux", 4],
    ["atlas", 1],
    ["notes", 1],
  ]);
  expect(groups[0]!.lead.id).toBe("/Users/me/src/cmux");
  expect(guessProjectRepo("/Users/me/src/app/.claude/worktrees/fix-login")).toMatchObject({
    name: "app",
    branch: "fix-login",
  });
  expect(guessProjectRepo("/Users/me/conductor/workspaces/app/tokyo")).toMatchObject({ name: "app", branch: "tokyo" });
  expect(guessProjectRepo("/Users/me/.codex/worktrees/1a2b/app")).toMatchObject({ name: "app" });
  expect(guessProjectRepo("/Users/me/src/app")).toBeUndefined();
});

test("clones of the same name with no repository stay apart", () => {
  const clones = [
    { id: "/Users/me/wt/a/cmux", label: "cmux" },
    { id: "/Users/me/wt/b/cmux", label: "cmux" },
  ];
  expect(groupByRepo(clones).length).toBe(2);
});

test("no words: one row per repository, worktrees only for an opened one", () => {
  const groups = groupByRepo(folders);
  const closed = shownRepoRows(groups, "", new Set());
  expect(closed.map((row) => [row.group.name, row.worktrees.length])).toEqual([
    ["cmux", 0],
    ["atlas", 0],
    ["notes", 0],
  ]);
  const open = shownRepoRows(groups, "", new Set([groups[0]!.key]));
  expect(open[0]!.worktrees.map((worktree) => worktree.label)).toEqual([
    "issue-22273-runaway-children",
    "unread-ring-classic",
    "agent-caller-scoped",
  ]);
});

test("a search by branch lists that worktree under its repository; by the repository's name, the row once", () => {
  const groups = groupByRepo(folders);
  const byBranch = shownRepoRows(groups, "unread", new Set());
  expect(byBranch.map((row) => [row.group.name, row.worktrees.map((worktree) => worktree.label)])).toEqual([
    ["cmux", ["unread-ring-classic"]],
  ]);
  const byName = shownRepoRows(groups, "cmux", new Set());
  expect(byName.map((row) => [row.group.name, row.worktrees.length])).toEqual([["cmux", 0]]);
  // Words across the repository and a branch narrow to that worktree.
  expect(shownRepoRows(groups, "cmux issue", new Set())[0]!.worktrees.map((worktree) => worktree.label)).toEqual([
    "issue-22273-runaway-children",
  ]);
  expect(shownRepoRows(groups, "atl", new Set()).map((row) => row.group.name)).toEqual(["atlas"]);
  expect(shownRepoRows(groups, "zzz", new Set())).toEqual([]);
});

test("the host's repos are checked before use", () => {
  expect(
    parseProjectRepos({
      "/a": { root: "/a", top: "/a", name: "a", branch: "main", github: "o/a" },
      "/b": { root: "relative", name: "b" },
      "/c": { root: "/c", name: "" },
      "/d": { root: "/d", name: "d", github: "not a repo" },
      "/e": "nope",
    }),
  ).toEqual({
    "/a": { root: "/a", top: "/a", name: "a", branch: "main", github: "o/a" },
    "/d": { root: "/d", name: "d" },
  });
  expect(parseProjectRepos(undefined)).toEqual({});
  expect(parseProjectRepos([1])).toEqual({});
});

test("a folder inside a checkout is named by its path below it, never as the checkout", () => {
  const root = "/Users/me/src/cmux";
  const lanePath = "/Users/me/.cmux/worktrees/cmux/picker";
  const main: RepoFolder = { id: root, label: "cmux", repo: { root, top: root, name: "cmux", branch: "main" } };
  const sub: RepoFolder = { id: `${root}/web`, label: "web", repo: { root, top: root, name: "cmux", branch: "main" } };
  const laneSub: RepoFolder = {
    id: `${lanePath}/web/src`,
    label: "src",
    repo: { root, top: lanePath, name: "cmux", branch: "feat/picker" },
  };
  const laneTop: RepoFolder = {
    id: lanePath,
    label: "picker",
    repo: { root, top: lanePath, name: "cmux", branch: "feat/picker" },
  };
  expect(worktreeName(main)).toBe("main");
  expect(worktreeName(sub)).toBe("web");
  expect(worktreeName(laneSub)).toBe("feat/picker/web/src");
  expect(worktreeName(laneTop)).toBe("feat/picker");
  expect([main, sub, laneSub, laneTop].map(isMainCheckout)).toEqual([true, false, false, false]);
  // The composer strip adds this beside its branch control: "cmux · web", not "cmux".
  expect([main, sub, laneSub, laneTop].map(belowCheckout)).toEqual([undefined, "web", "web/src", undefined]);
});
