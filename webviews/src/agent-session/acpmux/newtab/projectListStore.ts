// The host's project list (`project.list`: folders and their repositories), kept for the next page's
// first frame. A New Tab page that just mounted has no list until the host answers, so its folder menu
// listed only the folders its chats named, by their folder's name and with no repository: a clone of
// GitHub's `cmux-workspace` in `~/cmux` read "cmux", and the folders only the project list holds were
// gone. Every agent page of this Mac shares one website data store (newtab/chatStore.ts), so a page
// writes the newest answer it received and the next page draws it until its own answer replaces it.
// Only pages that list this Mac's folders read or write it (`sharesChatList`).

const KEY = "cmux.acpmux.newTab.projects.v1";
/// More than a picker lists (AgentPaneOmnibar.maximumEntries); a bound on what one write holds.
const MAX_PROJECTS = 500;
/// The most text a read parses.
const MAX_TEXT = 512 * 1024;

export type StoredProjectList = { projects: string[]; repos: Record<string, unknown> };

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/// The last answer a page of this Mac kept, or undefined when none is kept or it is malformed.
export function storedProjectList(): StoredProjectList | undefined {
  let raw: string | null | undefined;
  try {
    raw = storage()?.getItem(KEY);
  } catch {
    return undefined;
  }
  // A write holds at most MAX_PROJECTS short paths; anything far larger is not this store's, and is
  // not parsed on a page's first render.
  if (!raw || raw.length > MAX_TEXT) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<StoredProjectList> | null;
    if (!value || !Array.isArray(value.projects)) return undefined;
    const projects = value.projects.filter((path): path is string => typeof path === "string" && path.length > 0);
    const repos = value.repos && typeof value.repos === "object" && !Array.isArray(value.repos) ? value.repos : {};
    return projects.length > 0 ? { projects, repos } : undefined;
  } catch {
    return undefined;
  }
}

/// Keeps a `project.list` answer of this Mac. An empty answer keeps nothing: a page the host has not
/// wired yet answers none, and the next page should still start from the real list.
export function storeProjectList(answer: { projects?: unknown; repos?: unknown } | undefined): void {
  const projects = Array.isArray(answer?.projects)
    ? answer.projects
        .filter((path): path is string => typeof path === "string" && path.length > 0)
        .slice(0, MAX_PROJECTS)
    : [];
  if (projects.length === 0) return;
  const given = answer?.repos && typeof answer.repos === "object" && !Array.isArray(answer.repos) ? answer.repos : {};
  const repos: Record<string, unknown> = {};
  for (const path of projects) {
    const repo = (given as Record<string, unknown>)[path];
    if (repo !== undefined) repos[path] = repo;
  }
  const text = JSON.stringify({ projects, repos });
  try {
    const store = storage();
    if (store && store.getItem(KEY) !== text) store.setItem(KEY, text);
  } catch {
    // A full or blocked store leaves each page its own list, as before.
  }
}
