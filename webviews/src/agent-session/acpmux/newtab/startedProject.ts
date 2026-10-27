// The project of the chat the person last picked and started (Leo 2026-10-21: "we dont wanna have
// stuff constantly get clobbered by agents making projects and then the new workspace has to keep
// redoing the default... your recently PICKED AND STARTED CHAT... makes more sense"). A New Tab with
// no folder of its own starts there. Only a send the person made from a composer (New Tab's field,
// a new chat's composer) writes it; chats agents, the CLI or the socket start never do, so their
// folders (lanes, worktrees, briefs) never become the default. The newest chat's folder
// (sessionList mostRecentProject) is only the fallback while nothing was started this way.
// The app keeps it across launches (`newTab.remember` `started`, the New Tab context's
// `startedProject`): an agent page's own storage ends with the launch. This run's copy is here, so
// a page whose context was made before the latest send still names it.

const KEY = "cmux.acpmux.newTab.startedProject.v1";

function storage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/// A folder a chat can start in that is a project: absolute, not `/`, `/Users`, a home folder, or a
/// private agent-home folder (sessionList isAgentHome).
export function isStartableProject(folder: string | undefined): folder is string {
  if (!folder?.startsWith("/")) return false;
  if (/^\/(?:(?:Users|home)(?:\/[^/]+)?)?\/?$/.test(folder)) return false;
  return !/\/Library\/Application Support\/cmux\/agent-home(?:\/|$)/.test(folder);
}

/// The person started a chat in `folder` from a composer: it becomes the default project. Anything
/// else (no project, another machine's folder) leaves the default as it was.
export function rememberStartedProject(
  folder: string | undefined,
  post: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): void {
  if (!isStartableProject(folder)) return;
  const started = folder.replace(/\/+$/, "");
  try {
    storage()?.setItem(KEY, started);
  } catch {
    // A full or blocked store: the app's copy still names it on the next page.
  }
  void post("newTab.remember", { started }).catch(() => undefined);
}

/// The folder this run's pages last started a chat in, if any.
export function rememberedStartedProject(): string | undefined {
  try {
    const value = storage()?.getItem(KEY);
    return isStartableProject(value ?? undefined) ? (value as string) : undefined;
  } catch {
    return undefined;
  }
}
