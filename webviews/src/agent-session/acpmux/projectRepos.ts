// Folders grouped by their repository for the project pickers (Austin and Leo 2026-10-20: the
// folder popover listed every worktree of cmux as a project of its own, "agent-caller-scoped-…",
// "issue-22273-…", each with a letter tile). A worktree is a branch of one project, not a project:
// the popover draws one row per repository and its other worktrees one level under it.
//
// The host reads each folder's repository from its `.git` (`project.list` answers `repos`,
// AgentPaneProjectRepo.swift: the main checkout's folder, the name, the branch, the GitHub
// repository). Without it (an older host, a gallery state) the usual worktree homes stand in:
// `~/.cmux/worktrees/<repo>/<lane>`, `<repo>/.worktrees/<lane>`, `<repo>/.claude/worktrees/<lane>`,
// Conductor's `workspaces/<repo>/<lane>` and Codex's `.codex/worktrees/<id>/<repo>`.

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
export type RepoFolder = { id: string; label: string; repo?: ProjectRepo };

/// One repository's folders, in the order given (newest first). `lead` is what its row picks: the
/// current folder when it is one of them, else the main checkout, else the newest.
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
export function groupByRepo<T extends RepoFolder>(folders: readonly T[], current?: string): RepoGroup<T>[] {
  const known = folders.flatMap((folder) => (folder.repo ? [folder.repo] : []));
  // Each name's repository, or null when two repositories share it: a guess can't tell which.
  const byName = new Map<string, ProjectRepo | null>();
  for (const repo of known) {
    const name = repo.name.toLowerCase();
    const seen = byName.get(name);
    byName.set(name, seen === undefined || (seen && repoKey(seen) === repoKey(repo)) ? repo : null);
  }
  // The checkouts the host named: a worktree's own top with its branch, and its main checkout.
  const checkouts = known.flatMap((repo): [string, ProjectRepo][] => {
    const { branch: _branch, ...main } = repo;
    return [
      [trim(repo.top ?? repo.root), repo],
      [trim(repo.root), { ...main, top: repo.root }],
    ];
  });
  const resolve = (folder: T): ProjectRepo | undefined => {
    if (folder.repo) return folder.repo;
    const id = trim(folder.id);
    const holder = checkouts
      .filter(([top]) => id === top || id.startsWith(top + "/"))
      .sort(([a], [b]) => b.length - a.length)[0];
    if (holder) return holder[1];
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
    groups.set(key, [...(groups.get(key) ?? []), folder]);
  }
  return [...groups].map(([key, members]) => {
    const repo = members.map((member) => member.repo).find(Boolean);
    const lead =
      members.find((member) => member.id === current) ??
      members.find((member) => member.repo && isMainCheckout(member)) ??
      members.find((member) => !member.repo) ??
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
export function projectRows<T extends { cwd: string; label: string; repo?: ProjectRepo }>(
  projects: readonly T[],
  current?: string,
): T[] {
  const folders = projects.map((project) => ({
    id: project.cwd,
    label: project.label,
    ...(project.repo ? { repo: project.repo } : {}),
    project,
  }));
  return groupByRepo(folders, current).map((group) => group.lead.project);
}

/// The projects in the order they were last used: those a chat used, newest chat first, then the
/// rest in the order given.
export function byRecentUse<T extends { cwd: string }>(projects: readonly T[], recent: readonly string[]): T[] {
  const rank = new Map(recent.map((cwd, index) => [trim(cwd), index]));
  const order = (project: T) => rank.get(trim(project.cwd)) ?? recent.length;
  return [...projects].sort((a, b) => order(a) - order(b));
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
  const ids = group.members.map((other) => trim(other.id));
  let common = ids[0] ?? "";
  for (const id of ids) while (common && !(id + "/").startsWith(common + "/")) common = common.replace(/\/?[^/]*$/, "");
  const below = trim(member.id).slice(common.length);
  return `${member.label} ${worktreeName(member)} ${below}`.toLowerCase();
}
