// The project pickers fold a repository's worktrees under one row (projectRepos.ts): Austin's list
// showed each cmux worktree as a project of its own.
import { expect, test } from "bun:test";
import {
  belowCheckout,
  byRecentUse,
  chooserRows,
  groupByRepo,
  guessProjectRepo,
  isMainCheckout,
  parseProjectRepos,
  projectRows,
  shownRepoRows,
  worktreeName,
  type RepoFolder,
} from "./projectRepos";
import { githubRepository } from "./githubRepository";

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

test("GitHub remotes normalize to one identity before project grouping", () => {
  const cases: Array<[unknown, string | undefined]> = [
    ["manaflow-ai/cmux", "manaflow-ai/cmux"],
    ["github.com/manaflow-ai/cmux", "manaflow-ai/cmux"],
    ["https://github.com/manaflow-ai/cmux.git", "manaflow-ai/cmux"],
    ["https://www.github.com/manaflow-ai/cmux/", "manaflow-ai/cmux"],
    ["ssh://git@github.com/manaflow-ai/cmux.git", "manaflow-ai/cmux"],
    ["git://github.com/manaflow-ai/cmux.git", "manaflow-ai/cmux"],
    ["git@github.com:manaflow-ai/cmux.git", "manaflow-ai/cmux"],
    ["https://github.com/acme/.github.git", "acme/.github"],
    ["git@github.com:acme/_tools.git", "acme/_tools"],
    ["acme/-dash", "acme/-dash"],
    ["acme/..", undefined],
    ["https://gitlab.com/manaflow-ai/cmux.git", undefined],
    ["https://github.com/manaflow-ai/cmux/issues", undefined],
    ["github.com/manaflow-ai/cmux/extra", undefined],
    ["not a repository", undefined],
    [null, undefined],
  ];
  for (const [remote, expected] of cases) expect(githubRepository(remote)).toBe(expected);

  const parsed = parseProjectRepos({
    "/Users/me/src/cmux": {
      root: "/Users/me/src/cmux",
      name: "cmux",
      github: "https://github.com/manaflow-ai/cmux.git",
    },
    "/Users/me/.cmux/worktrees/cmux/fix": {
      root: "/Users/me/src/cmux",
      name: "cmux",
      branch: "fix",
      github: "git@github.com:manaflow-ai/cmux.git",
    },
  });
  expect(Object.values(parsed).map((repo) => repo.github)).toEqual(["manaflow-ai/cmux", "manaflow-ai/cmux"]);
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

// Leo's New Tab picker on nightly 331e2e9 (2026-10-21): "cmux · ~/Projects" twice (the main clone
// and the lane mirror's worktrees, 19 and 63 branches), each lane's checkout and `.noindex` scratch
// folder as a project, and the home folder.
const leo = "/Users/leo/Projects";
const main = { root: `${leo}/cmux`, top: `${leo}/cmux`, name: "cmux", github: "manaflow-ai/cmux" };
const mirror = `${leo}/.wt-mirrors/manaflow-ai/cmux.git`;
const mirrored = (lane: string): RepoFolder => ({
  id: `${leo}/checkouts/cmux/${lane}`,
  label: lane,
  repo: { root: mirror, top: `${leo}/checkouts/cmux/${lane}`, name: "cmux", branch: lane, github: "manaflow-ai/cmux" },
});
const picker: RepoFolder[] = [
  { id: leo, label: "Projects" },
  mirrored("lane-host-fg"),
  { id: `${leo}/cmux`, label: "cmux", repo: { ...main, branch: "main" } },
  {
    id: `${leo}/leo-workspace`,
    label: "leo-workspace",
    repo: { root: `${leo}/leo-workspace`, name: "leo-workspace", github: "teamleaderleo/leo-workspace" },
  },
  // A chat's folder the host was not asked about.
  { id: `${leo}/checkouts/cmux/queued-agent-from`, label: "queued-agent-from" },
  { id: `${leo}/cmux-live-block.noindex`, label: "cmux-live-block.noindex" },
  { id: `${leo}/cmux/webviews`, label: "webviews" },
  mirrored("cg-queue--collapsed-queue"),
  { id: "/Users/leo/.cmux/worktrees.noindex/cmux/steer-folds", label: "steer-folds" },
  { id: "/Users/leo", label: "~" },
  { id: "/Users/leo/Library/Caches/x.noindex/scratch", label: "scratch" },
];

test("one row per repository: every clone and lane checkout of one GitHub repository folds together", () => {
  const groups = groupByRepo(picker, leo);
  expect(groups.map((group) => [group.name, group.members.length])).toEqual([
    ["Projects", 1],
    ["cmux", 6],
    ["leo-workspace", 1],
  ]);
  const cmuxRow = groups[1]!;
  // The main clone leads; the rest are its branches, newest first.
  expect(cmuxRow.lead.id).toBe(`${leo}/cmux`);
  expect(cmuxRow.members.filter((member) => member !== cmuxRow.lead).map(worktreeName)).toEqual([
    "lane-host-fg",
    "queued-agent-from",
    "webviews",
    "cg-queue--collapsed-queue",
    "steer-folds",
  ]);
  // A folder inside the main checkout is named by its path below it, not the checkout's branch.
  expect(belowCheckout(cmuxRow.members.find((member) => member.label === "webviews")!)).toBe("webviews");
});

test("scratch folders in no repository and the home folder are left out unless current", () => {
  const ids = (current?: string) => groupByRepo(picker, current).flatMap((group) => group.members.map((m) => m.id));
  expect(ids(leo)).not.toContain(`${leo}/cmux-live-block.noindex`);
  expect(ids(leo)).not.toContain("/Users/leo");
  expect(ids(leo)).not.toContain("/Users/leo/Library/Caches/x.noindex/scratch");
  expect(ids("/Users/leo")).toContain("/Users/leo");
  expect(ids(`${leo}/cmux-live-block.noindex`)).toContain(`${leo}/cmux-live-block.noindex`);
});

test("a lane checkout's guess joins only an unambiguous repository of that name", () => {
  const other = { root: "/Users/me/fork/cmux", name: "cmux", github: "someone/cmux" };
  const ambiguous: RepoFolder[] = [
    { id: "/Users/me/src/cmux", label: "cmux", repo: { root: "/Users/me/src/cmux", name: "cmux", github: "o/cmux" } },
    { id: "/Users/me/fork/cmux", label: "cmux", repo: other },
    { id: "/Users/me/checkouts/cmux/lane", label: "lane" },
  ];
  expect(groupByRepo(ambiguous).map((group) => [group.name, group.members.length])).toEqual([
    ["cmux", 1],
    ["cmux", 1],
    ["cmux", 1],
  ]);
  expect(guessProjectRepo("/Users/me/Projects/checkouts/cmux/feat--picker")).toMatchObject({
    name: "cmux",
    branch: "feat/picker",
  });
  expect(guessProjectRepo("/Users/me/Projects/cmux-worktrees/picker-23900")).toMatchObject({
    name: "cmux",
    branch: "picker-23900",
  });
});

test("a folder the host said nothing about never joins a known repository by its name alone", () => {
  // The host knows only a lane of acme/web (root in a bare mirror, so no main checkout to hold it).
  const web = { root: "/Users/me/.mirrors/acme/web.git", name: "web", github: "acme/web" };
  const unrelated: RepoFolder[] = [
    {
      id: "/Users/me/checkouts/web/lane1",
      label: "lane1",
      repo: { ...web, top: "/Users/me/checkouts/web/lane1", branch: "lane1" },
    },
    { id: "/Users/me/Projects/site/web", label: "web" },
  ];
  const groups = groupByRepo(unrelated);
  expect(groups.map((group) => [group.name, group.lead.id])).toEqual([
    ["web", "/Users/me/checkouts/web/lane1"],
    ["web", "/Users/me/Projects/site/web"],
  ]);
});

test("the flat pickers list each repository once, by its lead, and no scratch folders", () => {
  const projects = [
    {
      cwd: "/Users/me/Projects/cmux",
      label: "cmux",
      repo: { root: "/Users/me/Projects/cmux", name: "cmux", github: "o/cmux", branch: "main" },
    },
    { cwd: "/Users/me/Projects/checkouts/cmux/lane-a", label: "lane-a" },
    { cwd: "/Users/me/Projects/cmux-live-block.noindex", label: "cmux-live-block.noindex" },
    { cwd: "/Users/me", label: "me" },
    { cwd: "/Users/me/notes", label: "notes" },
  ];
  expect(projectRows(projects).map((project) => project.cwd)).toEqual(["/Users/me/Projects/cmux", "/Users/me/notes"]);
  expect(projectRows(projects, "/Users/me/Projects/checkouts/cmux/lane-a").map((project) => project.cwd)).toEqual([
    "/Users/me/Projects/checkouts/cmux/lane-a",
    "/Users/me/notes",
  ]);
});

test("projects a chat used come first, newest chat first; the rest keep their order", () => {
  const projects = ["/a", "/b", "/c", "/d"].map((cwd) => ({ cwd }));
  expect(byRecentUse(projects, ["/c/", "/a"]).map((project) => project.cwd)).toEqual(["/c", "/a", "/b", "/d"]);
});

// Leo 2026-10-21 on the New Tab picker: "cmux · ~/Projects" twice, then lane folders as projects
// ("leo--ask-cost-dollar" lived in `checkouts/cmux/`, "cmux-new-tab-order.noindex"). A main checkout,
// three Git worktrees (the host read their `.git` files), a second clone of the same GitHub
// repository, a `.noindex` folder, the lane mirror, and lane checkouts the host said nothing about.
test("one row per repository with its worktrees under it, and no scratch rows", () => {
  const p = "/Users/me/Projects";
  const app = { name: "app", github: "acme/app" };
  const worktree = (id: string, branch: string): RepoFolder => ({
    id,
    label: id.split("/").pop()!,
    repo: { ...app, root: `${p}/app`, top: id, branch },
  });
  const fixture: RepoFolder[] = [
    { id: `${p}/app`, label: "app", repo: { ...app, root: `${p}/app`, top: `${p}/app`, branch: "main" } },
    worktree(`${p}/checkouts/app/feat--icons`, "feat/icons"),
    { id: `${p}/app-new-tab-order.noindex`, label: "app-new-tab-order.noindex" },
    worktree("/Users/me/.cmux/worktrees.noindex/app/fix-dots", "fix-dots"),
    { id: `${p}/checkouts/app/leo--ask-cost-dollar`, label: "leo--ask-cost-dollar" },
    {
      id: `${p}/app-next-dev`,
      label: "app-next-dev",
      repo: { ...app, root: `${p}/app-next-dev`, top: `${p}/app-next-dev` },
    },
    { id: `${p}/.wt-mirrors/acme/app.git/hooks`, label: "hooks" },
    worktree(`${p}/app-dedupe`, "dedupe"),
    { id: `${p}/notes`, label: "notes" },
  ];
  const groups = groupByRepo(fixture);
  expect(groups.map((group) => [group.name, group.lead.id])).toEqual([
    ["app", `${p}/app`],
    ["notes", `${p}/notes`],
  ]);
  expect(groups[0]!.members.slice(1).map(worktreeName)).toEqual([
    "feat/icons",
    "fix-dots",
    "leo/ask-cost-dollar",
    "app-next-dev",
    "dedupe",
  ]);
  // The flat pickers (New Tab hero) list the same: one project per repository, no scratch.
  const flat = projectRows(fixture.map((folder) => ({ cwd: folder.id, label: folder.label, repo: folder.repo })));
  expect(flat.map((project) => project.cwd)).toEqual([`${p}/app`, `${p}/notes`]);
});

// Codex review of #24310: a name is no evidence. A folder called `leo--feature` or `design--notes`
// with no repository metadata (an older host, the gallery) is an ordinary folder and stays listed.
test("a folder named like a lane but outside a lane root stays listed", () => {
  const plain: RepoFolder[] = [
    { id: "/Users/me/leo--feature", label: "leo--feature" },
    { id: "/Users/me/Projects/design--notes", label: "design--notes" },
  ];
  expect(groupByRepo(plain).map((group) => group.lead.id)).toEqual([
    "/Users/me/leo--feature",
    "/Users/me/Projects/design--notes",
  ]);
  expect(projectRows(plain.map((folder) => ({ cwd: folder.id, label: folder.label }))).length).toBe(2);
});

// Leo, "why is this all misaligned in the agent chat project selectin": the agent chat's project
// picker listed two lanes' worktrees (`~/wt/lanes/<lane>/cmux`) as two "cmux" projects of their own.
test("the project chooser lists a lane's worktree under its repository, and finds it by search", () => {
  const main = { root: "/Users/sample/Projects/cmux", name: "cmux", branch: "main", github: "sample/cmux" };
  const projects = [
    { cwd: "/Users/sample/wt/lanes/lane-adopt/cmux", label: "cmux" },
    { cwd: "/Users/sample/wt/lanes/next-reds/cmux", label: "cmux" },
    { cwd: "/Users/sample/Projects/cmux", label: "cmux", repo: main },
    { cwd: "/Users/sample/Projects", label: "Projects" },
    { cwd: "/srv/atlas", label: "atlas", peer: "build-box", host: "build-box" },
  ];
  const cwds = (query: string, current?: string) => chooserRows(projects, query, current).map((row) => row.cwd);
  // One cmux row (its main checkout), the plain folder, then the other machine's folder.
  expect(cwds("")).toEqual(["/Users/sample/Projects/cmux", "/Users/sample/Projects", "/srv/atlas"]);
  // The current folder leads its repository's row.
  expect(cwds("", "/Users/sample/wt/lanes/next-reds/cmux")[0]).toBe("/Users/sample/wt/lanes/next-reds/cmux");
  // A search for the repository lists it once; one that names a lane finds that lane's worktree.
  expect(cwds("cmux")).toEqual(["/Users/sample/Projects/cmux"]);
  expect(cwds("next-reds")).toEqual(["/Users/sample/wt/lanes/next-reds/cmux"]);
  expect(cwds("wt/lanes")).toEqual(["/Users/sample/wt/lanes/lane-adopt/cmux", "/Users/sample/wt/lanes/next-reds/cmux"]);
  expect(cwds("build")).toEqual(["/srv/atlas"]);
  // A linked worktree the host read keeps its repository, wherever it lives.
  const read = [
    { cwd: "/Users/sample/Projects/cmux", label: "cmux", repo: main },
    {
      cwd: "/Users/sample/scratch/fix-login",
      label: "fix-login",
      repo: { ...main, top: "/Users/sample/scratch/fix-login", branch: "fix-login" },
    },
  ];
  expect(chooserRows(read, "").map((row) => row.cwd)).toEqual(["/Users/sample/Projects/cmux"]);
  expect(chooserRows(read, "fix").map((row) => row.cwd)).toEqual(["/Users/sample/scratch/fix-login"]);
});

test("a lane's worktree under wt/lanes is named for its repository and its lane", () => {
  expect(guessProjectRepo("/Users/sample/wt/lanes/next-reds/cmux")).toMatchObject({
    name: "cmux",
    branch: "next-reds",
  });
});
