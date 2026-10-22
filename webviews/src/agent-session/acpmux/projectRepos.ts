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
    repos[cwd] = {
      root,
      ...(typeof top === "string" && top.startsWith("/") ? { top } : {}),
      name,
      ...(typeof branch === "string" && branch ? { branch } : {}),
      ...(typeof github === "string" && /^[\w.-]+\/[\w.-]+$/.test(github) ? { github } : {}),
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

/// The folders grouped by repository, each group where its newest folder was. A folder in no
/// repository is a group of its own; one whose name is a guessed repository's joins it as that
/// repository's main checkout (`~/Projects/cmux` with `~/.cmux/worktrees/cmux/*`).
export function groupByRepo<T extends RepoFolder>(folders: readonly T[], current?: string): RepoGroup<T>[] {
  const repos = new Map(folders.map((folder) => [folder.id, folderRepo(folder)]));
  const guessed = new Set([...repos.values()].flatMap((repo) => (repo?.root.startsWith(GUESSED) ? [repo.root] : [])));
  const keyOf = (folder: T): string => {
    const repo = repos.get(folder.id);
    if (repo) return repo.root;
    const named = GUESSED + folder.label.toLowerCase();
    return guessed.has(named) ? named : folder.id;
  };
  const groups = new Map<string, T[]>();
  for (const folder of folders) {
    const key = keyOf(folder);
    groups.set(key, [...(groups.get(key) ?? []), folder]);
  }
  return [...groups].map(([key, members]) => {
    const repo = members.map((member) => repos.get(member.id)).find(Boolean);
    const lead =
      members.find((member) => member.id === current) ??
      members.find((member) => trim(member.id) === key || !repos.get(member.id)) ??
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
