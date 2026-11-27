// Folders grouped by their repository for the project pickers (Austin and Leo 2026-10-20: the
// folder popover listed every worktree of cmux as a project of its own, "agent-caller-scoped-…",
// "issue-22273-…", each with a letter tile). A worktree is a branch of one project, not a project:
// the popover draws one row per repository and its other worktrees one level under it.
//
// The host reads each folder's repository from its `.git` (`project.list` answers `repos`,
// AgentPaneProjectRepo.swift: the main checkout's folder, the name, the branch, the GitHub
// repository). Without it (an older host, a gallery state) the usual worktree homes stand in:
// `~/.cmux/worktrees/<repo>/<lane>`, `<repo>/.worktrees/<lane>`, `<repo>/.claude/worktrees/<lane>`,
// Conductor's `workspaces/<repo>/<lane>`, Codex's `.codex/worktrees/<id>/<repo>` and a lane's
// `wt/lanes/<lane>/<repo>`.

import { githubRepository } from "./githubRepository";

/// A folder's repository, as the host read it.
export type ProjectRepo = {
  /// The main checkout's folder; every worktree of one repository has the same.
  root: string;
  /// The checkout (main or worktree) holding the folder: a folder inside it is named by its path below.
  top?: string;
  name: string;
  /// The folder's branch; none while detached.
  branch?: string;
  /// `owner/name` of its GitHub `origin`.
  github?: string;
};

/// The `repos` of a `project.list` answer, each checked: anything malformed is left out.
export function parseProjectRepos(value: unknown): Record<string, ProjectRepo> {
  const repos: Record<string, ProjectRepo> = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return repos;
  for (const [cwd, entry] of Object.entries(value as Record<string, unknown>)) {
    if (!entry || typeof entry !== "object") continue;
    const { root, top, name, branch, github } = entry as Record<string, unknown>;
    if (typeof root !== "string" || !root.startsWith("/") || typeof name !== "string" || !name) continue;
    const repository = githubRepository(github);
    repos[cwd] = {
      root,
      ...(typeof top === "string" && top.startsWith("/") ? { top } : {}),
      name,
      ...(typeof branch === "string" && branch ? { branch } : {}),
      ...(repository ? { github: repository } : {}),
    };
  }
  return repos;
}

const trim = (path: string) => path.replace(/(.)\/+$/, "$1");
const baseName = (path: string) => trim(path).split("/").pop() ?? path;

/// The repository a worktree's path names, for a folder the host said nothing about. `root` is a
/// stand-in key (the repository's folder is not known), shared by every worktree of that name.
export function guessProjectRepo(cwd: string): ProjectRepo | undefined {
  const path = trim(cwd);
  const patterns: [RegExp, (match: RegExpMatchArray) => { name: string; branch?: string }][] = [
    [/\/\.cmux\/worktrees(?:\.noindex)?\/([^/]+)\/([^/]+)$/, (m) => ({ name: m[1]!, branch: m[2]! })],
    [/\/conductor\/workspaces\/([^/]+)\/([^/]+)$/, (m) => ({ name: m[1]!, branch: m[2]! })],
    [/\/\.codex\/worktrees\/[^/]+\/([^/]+)$/, (m) => ({ name: m[1]! })],
    [/\/([^/]+)\/(?:\.worktrees|\.claude\/worktrees)\/([^/]+)$/, (m) => ({ name: m[1]!, branch: m[2]! })],
    // Lane checkouts: `checkouts/<repo>/<branch>` (a branch's `/` written `--`) and `<repo>-worktrees/<lane>`.
    [/\/checkouts\/([^/]+)\/([^/]+)$/, (m) => ({ name: m[1]!, branch: m[2]!.replaceAll("--", "/") })],
    [/\/([^/]+)-worktrees\/([^/]+)$/, (m) => ({ name: m[1]!, branch: m[2]! })],
    // A lane's own worktree, `wt/lanes/<lane>/<repo>`: named for its repository, told apart by its lane.
    [/\/wt\/lanes\/([^/]+)\/([^/]+)$/, (m) => ({ name: m[2]!, branch: m[1]! })],
  ];
  for (const [pattern, read] of patterns) {
    const match = path.match(pattern);
    if (match) {
      const { name, branch } = read(match);
      return { root: GUESSED + name.toLowerCase(), name, ...(branch ? { branch } : {}) };
    }
  }
  return undefined;
}

/// A guessed repository's key: never a path.
const GUESSED = "\u0000repo:";

/// A folder the pickers offer: its path (`id`), name and, when known, its repository.
export type DisplayGroup = { key: string; name: string; lead: string; mainLead: string; github?: string; hidden: boolean };
export type RepoFolder = { id: string; label: string; repo?: ProjectRepo; displayGroup?: DisplayGroup };

/// One repository's folders, in the order given (newest first). `lead` is what its row picks.
export type RepoGroup<T extends RepoFolder> = {
  key: string;
  name: string;
  github?: string;
  lead: T;
  /// Every folder of the repository, `lead` included, newest first.
  members: T[];
};

/// The folder's repository: the host's, else a guess from its path.
export function folderRepo(folder: RepoFolder): ProjectRepo | undefined {
  return folder.repo ?? guessProjectRepo(folder.id);
}

/// The home folder itself (`/Users/me`, `/home/me`): where a shell starts, not a project.
export function isHomeFolder(path: string): boolean {
  return /^\/(?:Users|home)\/[^/]+$/.test(trim(path));
}

/// A lane's or agent's scratch folder: Spotlight-hidden `.noindex` checkouts, caches, temp folders
/// and the lane mirrors (`.wt-mirrors/<owner>/<repo>.git`). Never a project row of its own; it shows
/// only folded under a repository it is known to belong to. Judged by where it lives, never by its
/// name alone: `~/leo--feature` is an ordinary folder, and a lane checkout under `checkouts/<repo>/`
/// is placed under its repository by `guessProjectRepo`.
export function isScratchFolder(path: string): boolean {
  return /\/[^/]+\.noindex(?:\/|$)|\/\.wt-mirrors\/|\/\.cache\/|^\/(?:private\/)?tmp\/|^\/(?:private\/)?var\/folders\//.test(
    trim(path),
  );
}

/// One repository however many clones hold it: its GitHub `owner/name`, else its main checkout.
const repoKey = (repo: ProjectRepo) => (repo.github ? "\u0000github:" + repo.github.toLowerCase() : repo.root);

/// The folders grouped by repository, each group where its newest folder was (Leo 2026-10-21: the
/// New Tab picker listed cmux twice, as "cmux · ~/Projects" with 19 branches and with 63, then
/// each lane's checkout as a project). Every clone and worktree of one GitHub repository is one row.
/// A folder the host said nothing about joins the repository whose checkout holds it, else the one
/// its worktree path names (`~/.cmux/worktrees/cmux/x`, `checkouts/cmux/x`: the host's repository
/// of that name when there is one), else a guessed one whose name is its own as the main checkout
/// (`~/Projects/cmux`), else it is a row of its own. A lane's scratch folder in no repository, and
/// the home folder, are left out unless current. The members carry their repository as resolved.
export function groupByRepo<T extends RepoFolder>(
  folders: readonly T[],
  current?: string,
  leadPreference: "current" | "main" = "current",
): RepoGroup<T>[] {
  // Native New Tab rows already carry Rust's opening-scoped membership and leads.
  // This is only a projection of that snapshot; legacy callers still resolve below.
  if (folders.some((folder) => folder.displayGroup)) {
    const native = new Map<string, RepoGroup<T>>();
    for (const folder of folders) {
      const display = folder.displayGroup;
      if (!display || display.hidden) continue;
      let group = native.get(display.key);
      if (!group) {
        group = { key: display.key, name: display.name, github: display.github, lead: folder, members: [] };
        native.set(display.key, group);
      }
      group.members.push(folder);
      if (folder.id === (leadPreference === "main" ? display.mainLead : display.lead)) group.lead = folder;
    }
    return [...native.values(), ...groupByRepo(folders.filter((folder) => !folder.displayGroup), current, leadPreference)];
  }
  const known = folders.flatMap((folder) => (folder.repo ? [folder.repo] : []));
  // Each name's repository, or null when two repositories share it: a guess can't tell which.
  const byName = new Map<string, ProjectRepo | null>();
  for (const repo of known) {
    const name = repo.name.toLowerCase();
    const seen = byName.get(name);
    byName.set(name, seen === undefined || (seen && repoKey(seen) === repoKey(repo)) ? repo : null);
  }
  // The checkouts the host named: a worktree's own top with its branch, and its main checkout.
  // By folder, the first named wins as before; a folder's holder is its nearest such ancestor, found
  // by walking up its path (a lookup per level, not a scan of every checkout: thousands of projects
  // made opening the picker lag).
  const checkouts = new Map<string, ProjectRepo>();
  for (const repo of known) {
    const { branch: _branch, ...main } = repo;
    const top = trim(repo.top ?? repo.root);
    if (!checkouts.has(top)) checkouts.set(top, repo);
    const root = trim(repo.root);
    if (!checkouts.has(root)) checkouts.set(root, { ...main, top: repo.root });
  }
  const holderOf = (id: string): ProjectRepo | undefined => {
    for (let path = id; path;) {
      const repo = checkouts.get(path);
      if (repo) return repo;
      const cut = path.lastIndexOf("/");
      if (cut <= 0) return undefined;
      path = path.slice(0, cut);
    }
    return undefined;
  };
  const resolve = (folder: T): ProjectRepo | undefined => {
    if (folder.repo) return folder.repo;
    const holder = holderOf(trim(folder.id));
    if (holder) return holder;
    const guess = guessProjectRepo(folder.id);
    const named = guess && byName.get(guess.name.toLowerCase());
    if (!guess || !named) return guess;
    const { top: _top, branch: _branch, ...repo } = named;
    return { ...repo, ...(guess.branch ? { branch: guess.branch } : {}) };
  };
  const resolved = folders.flatMap((folder): T[] => {
    const repo = resolve(folder);
    if (folder.id !== current && (isHomeFolder(folder.id) || (!repo && isScratchFolder(folder.id)))) return [];
    return [repo && repo !== folder.repo ? { ...folder, repo } : folder];
  });
  const guessed = new Set(
    resolved.flatMap((folder) => (folder.repo?.root.startsWith(GUESSED) ? [folder.repo.root] : [])),
  );
  const keyOf = (folder: T): string => {
    if (folder.repo) return repoKey(folder.repo);
    // Only a guessed repository takes a folder by its name: a folder the host said nothing about
    // is no checkout of a repository it knows (`~/Projects/site/web` is not acme/web).
    const label = folder.label.toLowerCase();
    return guessed.has(GUESSED + label) ? GUESSED + label : folder.id;
  };
  const groups = new Map<string, T[]>();
  for (const folder of resolved) {
    const key = keyOf(folder);
    const members = groups.get(key);
    if (members) members.push(folder);
    else groups.set(key, [folder]);
  }
  return [...groups].map(([key, members]) => {
    const repo = members.map((member) => member.repo).find(Boolean);
    const selected = members.find((member) => member.id === current);
    const selectedRoot = selected?.repo?.root;
    const lead =
      (leadPreference === "current" ? selected : undefined) ??
      (selectedRoot ? members.find((member) => member.id === selectedRoot && isMainCheckout(member)) : undefined) ??
      members.find(isMainCheckout) ??
      members.find((member) => !member.repo) ??
      selected ??
      members[0]!;
    return {
      key,
      name: repo?.name ?? lead.label,
      ...(repo?.github ? { github: repo.github } : {}),
      lead,
      members,
    };
  });
}

/// One project per repository for a picker that lists no worktrees (the New Tab hero and
/// environment card): each group's lead, so lane checkouts and scratch folders never fill it.
export function projectRows<T extends { cwd: string; label: string; repo?: ProjectRepo; displayGroup?: DisplayGroup }>(
  projects: readonly T[],
  current?: string,
): T[] {
  const folders = projects.map((project) => ({
    id: project.cwd,
    label: project.label,
    ...(project.repo ? { repo: project.repo } : {}),
    displayGroup: project.displayGroup,
    project,
  }));
  return groupByRepo(folders, current).map((group) => group.lead.project);
}

/// The rows of a project menu that lists no worktrees (ProjectChooser: the new chat's hero, the New
/// Tab headline). With no words, one per repository, its lead (as projectRows): a lane's worktree,
/// a scratch folder and the home folder are no rows of their own (Leo, "why is this all misaligned
/// in the agent chat project selectin": two lane worktrees of cmux listed as two "cmux" projects).
/// With words, every folder whose name, path or machine has them all, but a repository's other
/// folders only when the words name them, not just their repository (shownRepoRows): "cmux" lists
/// cmux once, "next-reds" its lane, so a hidden folder is one search away. Another machine's
/// folders are never folded (this Mac reads none of their repositories) and come last, as given.
export function chooserRows<T extends ChooserProject>(projects: readonly T[], query: string, current?: string): T[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const { local, remote, groups, ungrouped } = chooserBase(projects, current);
  if (words.length === 0) return [...groups.map((group) => group.lead.project), ...remote];
  const has = (project: T) => {
    const text = chooserText(project);
    return words.every((word) => text.includes(word));
  };
  const rows: T[] = [];
  for (const { group, worktrees } of shownRepoRows(groups, query, NO_KEYS)) {
    if (has(group.lead.project)) rows.push(group.lead.project);
    for (const worktree of worktrees) rows.push(worktree.project);
  }
  // A folder no repository's row stands for (the home folder, a scratch folder): by its own words.
  for (const project of local) if (ungrouped.has(project) && has(project)) rows.push(project);
  for (const project of remote) if (has(project)) rows.push(project);
  return rows;
}

type ChooserProject = { cwd: string; label: string; repo?: ProjectRepo; displayGroup?: DisplayGroup; peer?: string; host?: string };
type ChooserFolder<T> = { id: string; label: string; repo?: ProjectRepo; project: T };
type ChooserBase<T> = { local: T[]; remote: T[]; groups: RepoGroup<ChooserFolder<T>>[]; ungrouped: Set<T> };
const NO_KEYS: ReadonlySet<string> = new Set();

/// What a search of the chooser does not depend on, kept per projects list (its last `current`): the split by machine
/// and the grouping by repository. Each typed letter regrouped every folder: at 1,100 projects 1.0 ms of the 1.2-1.8 ms
/// a letter cost, at 11,000 12 of 14-27 ms (test/project-chooser-search.test.ts). Keyed on the list, so a list
/// nothing holds any more is collected with its entry.
const chooserBases = new WeakMap<readonly object[], { current: string | undefined; base: ChooserBase<object> }>();
function chooserBase<T extends ChooserProject>(projects: readonly T[], current: string | undefined): ChooserBase<T> {
  const kept = chooserBases.get(projects);
  if (kept && kept.current === current) return kept.base as ChooserBase<T>;
  const local = projects.filter((project) => !project.peer);
  const remote = projects.filter((project) => project.peer);
  const folders = local.map((project) => ({
    id: project.cwd,
    label: project.label,
    ...(project.repo ? { repo: project.repo } : {}),
    displayGroup: project.displayGroup,
    project,
  }));
  const groups = groupByRepo(folders, current);
  const grouped = new Set(groups.flatMap((group) => group.members.map((member) => member.project)));
  const ungrouped = new Set(local.filter((project) => !grouped.has(project)));
  const base: ChooserBase<T> = { local, remote, groups, ungrouped };
  chooserBases.set(projects, { current, base: base as ChooserBase<object> });
  return base;
}

/// A project's words for the chooser's search, lowercased once per project object, not once per letter typed.
const chooserTexts = new WeakMap<object, string>();
function chooserText(project: ChooserProject): string {
  let text = chooserTexts.get(project);
  if (text === undefined) {
    text = `${project.label} ${project.cwd} ${project.host ?? ""}`.toLowerCase();
    chooserTexts.set(project, text);
  }
  return text;
}

/// The chooser's rows as it read them before chooserBase and chooserText kept anything: every folder regrouped and
/// lowercased again per call. The oracle of test/project-chooser-search.test.ts.
export function chooserRowsScan<
  T extends { cwd: string; label: string; repo?: ProjectRepo; peer?: string; host?: string },
>(projects: readonly T[], query: string, current?: string): T[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const has = (project: T) => {
    const text = `${project.label} ${project.cwd} ${project.host ?? ""}`.toLowerCase();
    return words.every((word) => text.includes(word));
  };
  const local = projects.filter((project) => !project.peer);
  const remote = projects.filter((project) => project.peer);
  const folders = local.map((project) => ({
    id: project.cwd,
    label: project.label,
    ...(project.repo ? { repo: project.repo } : {}),
    project,
  }));
  const groups = groupByRepo(folders, current);
  if (words.length === 0) return [...groups.map((group) => group.lead.project), ...remote];
  const rows: T[] = [];
  for (const { group, worktrees } of shownRepoRowsScan(groups, query, new Set())) {
    if (has(group.lead.project)) rows.push(group.lead.project);
    rows.push(...worktrees.map((worktree) => worktree.project));
  }
  // A folder no repository's row stands for (the home folder, a scratch folder): by its own words.
  const grouped = new Set(groups.flatMap((group) => group.members.map((member) => member.project)));
  rows.push(...local.filter((project) => !grouped.has(project) && has(project)));
  return [...rows, ...remote.filter(has)];
}

/// The projects in the order they were last used: those a chat used, newest chat first, then the
/// rest in the order given.
export function byRecentUse<T extends { cwd: string }>(projects: readonly T[], recent: readonly string[]): T[] {
  const rank = new Map<string, number>();
  recent.forEach((cwd, index) => rank.set(trim(cwd), index));
  // Each project's rank read once, not in every comparison: thousands of folders at Leo's scale,
  // sorted again whenever another folder's chat becomes the newest (bench/session-scale-typing.bench.ts).
  return projects
    .map((project, index) => ({ project, index, order: rank.get(trim(project.cwd)) ?? recent.length }))
    .sort((a, b) => a.order - b.order || a.index - b.index)
    .map((ranked) => ranked.project);
}

/// What a worktree row is called: its branch, else its folder's name. A folder inside a checkout
/// is named by its path below it (`webviews/src`, `issue-22273/web`), so it never reads as the
/// checkout itself.
export function worktreeName(folder: RepoFolder): string {
  const repo = folderRepo(folder);
  const checkout = repo?.branch ?? baseName(repo?.top ?? folder.id);
  const below = belowCheckout(folder);
  if (!below) return checkout;
  return trim(repo!.top!) === trim(repo!.root) ? below : `${checkout}/${below}`;
}

/// The folder's path below its checkout's top (`webviews/src`), or nothing at the top itself.
export function belowCheckout(folder: RepoFolder): string | undefined {
  const top = folderRepo(folder)?.top;
  const id = trim(folder.id);
  if (!top || !id.startsWith(trim(top) + "/")) return undefined;
  return id.slice(trim(top).length + 1);
}

/// Whether the folder is its repository's main checkout itself, which needs no second name.
export function isMainCheckout(folder: RepoFolder): boolean {
  const repo = folderRepo(folder);
  return repo !== undefined && trim(folder.id) === trim(repo.root);
}

/// The rows a search shows: each group with any folder that matches every word, by the
/// repository's name, its GitHub name, a folder's name, branch or path. A folder other than the
/// lead gets a row of its own only when the words name it, not just its repository (typing "cmux"
/// lists cmux once, not each of its fifty worktrees). With no words, the `expanded` groups list
/// all their worktrees.
export function shownRepoRows<T extends RepoFolder>(
  groups: readonly RepoGroup<T>[],
  query: string,
  expanded: ReadonlySet<string>,
): { group: RepoGroup<T>; worktrees: T[] }[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0)
    return groups.map((group) => ({
      group,
      worktrees: expanded.has(group.key) ? group.members.filter((member) => member !== group.lead) : [],
    }));
  const rows: { group: RepoGroup<T>; worktrees: T[] }[] = [];
  for (const group of groups) {
    const { shared, own, worktree } = groupTexts(group);
    const members = group.members;
    // Which words the repository's name covers is the same for every member: read once per group.
    const unshared = words.filter((word) => !shared.includes(word));
    const matches = (index: number) => unshared.every((word) => own[index]!.includes(word));
    // Named by its own text: a word the repository's name alone does not cover.
    const named = (index: number) => unshared.some((word) => worktree(index).includes(word));
    let any = false;
    for (let index = 0; index < members.length && !any; index++) any = matches(index);
    if (!any) continue;
    const worktrees: T[] = [];
    for (let index = 0; index < members.length; index++)
      if (members[index] !== group.lead && matches(index) && named(index)) worktrees.push(members[index]!);
    rows.push({ group, worktrees });
  }
  return rows;
}

/// A group's lowercased search words, kept per group object: the repository's (`shared`), each member's own by its
/// index (`own`), and each member's worktree words, read only for a member that matches. Each typed letter
/// lowercased every member's label, name and path again, twice for a match.
type GroupTexts = { shared: string; own: string[]; worktree: (index: number) => string };
const groupTextsKept = new WeakMap<RepoGroup<RepoFolder>, GroupTexts>();
function groupTexts(group: RepoGroup<RepoFolder>): GroupTexts {
  const kept = groupTextsKept.get(group);
  if (kept && kept.own.length === group.members.length) return kept;
  const shared = `${group.name} ${group.github ?? ""}`.toLowerCase();
  const own = group.members.map((member) => `${member.label} ${worktreeName(member)} ${member.id}`.toLowerCase());
  const worktrees: (string | undefined)[] = [];
  const worktree = (index: number) => (worktrees[index] ??= worktreeText(group.members[index]!, group));
  const texts = { shared, own, worktree };
  groupTextsKept.set(group, texts);
  return texts;
}

/// The search rows as they were read before groupTexts kept anything. The oracle of
/// test/project-chooser-search.test.ts.
export function shownRepoRowsScan<T extends RepoFolder>(
  groups: readonly RepoGroup<T>[],
  query: string,
  expanded: ReadonlySet<string>,
): { group: RepoGroup<T>; worktrees: T[] }[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0)
    return groups.map((group) => ({
      group,
      worktrees: expanded.has(group.key) ? group.members.filter((member) => member !== group.lead) : [],
    }));
  const rows: { group: RepoGroup<T>; worktrees: T[] }[] = [];
  for (const group of groups) {
    const shared = `${group.name} ${group.github ?? ""}`.toLowerCase();
    const own = (member: T) => `${member.label} ${worktreeName(member)} ${member.id}`.toLowerCase();
    const matches = (member: T) => words.every((word) => shared.includes(word) || own(member).includes(word));
    // Named by its own text: a word the repository's name alone does not cover.
    const named = (member: T) =>
      words.some((word) => !shared.includes(word) && worktreeText(member, group).includes(word));
    if (!group.members.some(matches)) continue;
    rows.push({
      group,
      worktrees: group.members.filter((member) => member !== group.lead && matches(member) && named(member)),
    });
  }
  return rows;
}

/// A worktree's own words: its name, branch and the part of its path below what it shares with
/// the repository's other folders.
function worktreeText(member: RepoFolder, group: RepoGroup<RepoFolder>): string {
  const common = commonFolder(group);
  const below = trim(member.id).slice(common.length);
  return `${member.label} ${worktreeName(member)} ${below}`.toLowerCase();
}

/// The folder every member of the group is in, kept per group: a search reads it for each member,
/// and a repository with hundreds of worktrees made each typed letter walk them all again per member.
const commonFolders = new WeakMap<RepoGroup<RepoFolder>, string>();
function commonFolder(group: RepoGroup<RepoFolder>): string {
  const kept = commonFolders.get(group);
  if (kept !== undefined) return kept;
  const ids = group.members.map((other) => trim(other.id));
  let common = ids[0] ?? "";
  for (const id of ids) while (common && !(id + "/").startsWith(common + "/")) common = common.replace(/\/?[^/]*$/, "");
  commonFolders.set(group, common);
  return common;
}
