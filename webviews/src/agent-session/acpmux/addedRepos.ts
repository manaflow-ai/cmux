// The GitHub repositories the person added as a project (Add project… → GitHub), for the folder menu's one
// recent list (cmux#53226): the menu lists these, never every repository on the account, mixed with the folders
// by when each was last used. A repository with a folder of its own in the list (this Mac's clone of it, named
// by its `origin`) is that folder's row, never a second one.
//
// Kept in the page's storage, shared by this launch's pages; read only when the menu opens. A repository that
// was started in has a folder by then (its clone on this Mac, or its Cloud machine's folder), which the folder
// list keeps across launches.

export type AddedRepo = { fullName: string; private: boolean; at: number };

const KEY = "cmux.acpmux.addedGitHubRepos.v1";
/// The repositories kept; the least recently used goes first.
const MAX_REPOS = 50;

// This page's copy, for a store that is missing or refuses a write.
let memory: AddedRepo[] = [];

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage ?? (globalThis as { window?: { localStorage?: Storage } }).window?.localStorage;
  } catch {
    return undefined;
  }
}

function isAddedRepo(value: unknown): value is AddedRepo {
  const repo = value as Partial<AddedRepo> | null;
  return (
    typeof repo?.fullName === "string" &&
    /^[^/\s]+\/[^/\s]+$/.test(repo.fullName) &&
    typeof repo.at === "number" &&
    Number.isFinite(repo.at)
  );
}

/// The added repositories, most recently used first.
export function readAddedRepos(): AddedRepo[] {
  // This page's copy only when there is no store to read: an empty store is an empty list (forgotten
  // by another page, or cleared).
  let stored: unknown = memory;
  try {
    const store = storage();
    if (store) {
      const text = store.getItem(KEY);
      stored = text ? JSON.parse(text) : [];
    }
  } catch {
    stored = memory;
  }
  const list = Array.isArray(stored)
    ? stored.filter(isAddedRepo).map((repo) => ({ fullName: repo.fullName, private: repo.private === true, at: repo.at }))
    : [];
  return [...list].sort((a, b) => b.at - a.at);
}

/// The person added `repo` as a project, or picked it again: it becomes the newest.
export function rememberAddedRepo(repo: { fullName: string; private: boolean }, at = Date.now()): void {
  const key = repo.fullName.toLowerCase();
  const next = [
    { fullName: repo.fullName, private: repo.private, at },
    ...readAddedRepos().filter((other) => other.fullName.toLowerCase() !== key),
  ].slice(0, MAX_REPOS);
  memory = next;
  try {
    storage()?.setItem(KEY, JSON.stringify(next));
  } catch {
    // A full or blocked store: this page's copy still lists it.
  }
}

/// Forgets every added repository (tests).
export function forgetAddedRepos(): void {
  memory = [];
  try {
    storage()?.removeItem(KEY);
  } catch {
    // Nothing kept.
  }
}

/// When this Mac's chats last worked in a folder (App's `FolderRecency`), for ordering the added repositories
/// among the folders. Read only while the menu is open, so a chat working never draws a closed menu again.
let folderUseTime: (folder: string) => number | undefined = () => undefined;

export function setFolderUseTimes(read: (folder: string) => number | undefined): void {
  folderUseTime = read;
}

export function folderUsedAt(folder: string): number | undefined {
  return folderUseTime(folder.replace(/(.)\/+$/, "$1"));
}

/// Merges the added repositories (newest first) into the folder blocks (newest first, each with the time its
/// newest folder was used): each repository goes before the first block used before it. A block with no known
/// time (a folder no chat here worked in) is older than any repository.
export function mergeByRecentUse<B>(
  blocks: readonly { block: B; at: number | undefined }[],
  repos: readonly { repo: AddedRepo; block: B }[],
): B[] {
  const merged: B[] = [];
  let next = 0;
  for (const { block, at } of blocks) {
    while (next < repos.length && repos[next]!.repo.at > (at ?? -Infinity)) merged.push(repos[next++]!.block);
    merged.push(block);
  }
  while (next < repos.length) merged.push(repos[next++]!.block);
  return merged;
}
