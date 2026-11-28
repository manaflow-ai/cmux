import { seedCloudLastPick } from "../cloudLastPick";
import { isTemporaryFolder } from "../sessionList";

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
/// When this run last wrote the default (`Date.now()`): a slow start checks it before it writes.
const AT_KEY = "cmux.acpmux.newTab.startedProject.at.v1";

/// When this run's pages last wrote the default; 0 for never.
function rememberedAt(): number {
  try {
    return Number(storage()?.getItem(AT_KEY) ?? 0) || 0;
  } catch {
    return 0;
  }
}

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
  sentAt?: number,
): void {
  // A temporary folder (a scratch chat in /tmp) is no project to come back to (cmux#49610).
  if (!isStartableProject(folder) || isTemporaryFolder(folder)) return;
  // A start that settles after a newer pick or start (another page, while this one's chat was starting)
  // leaves that newer default as it is.
  if (sentAt !== undefined && rememberedAt() > sentAt) return;
  const started = folder.replace(/\/+$/, "");
  try {
    storage()?.setItem(KEY, started);
    storage()?.setItem(AT_KEY, String(Date.now()));
  } catch {
    // A full or blocked store: the app's copy still names it on the next page.
  }
  void post("newTab.remember", { started }).catch(() => undefined);
}

/// The folder this run's pages last started a chat in, if any.
export function rememberedStartedProject(): string | undefined {
  try {
    const value = storage()?.getItem(KEY);
    return isStartableProject(value ?? undefined) && !isTemporaryFolder(value ?? undefined)
      ? (value as string)
      : undefined;
  } catch {
    return undefined;
  }
}

/// The started projects a New Tab page may start on, newest first: this run's copy, then the app's
/// (`startedProject` in the page's context, kept across launches). Both, not the first alone: a run's
/// copy the host no longer lists (a removed worktree) gives way to the app's, never to a blank folder
/// chip (cmux#51272). Each trimmed of a trailing `/`, once.
export function startedProjectChoices(fromApp: string | undefined): string[] {
  const choices = [rememberedStartedProject(), fromApp]
    .filter((folder): folder is string => isStartableProject(folder) && !isTemporaryFolder(folder))
    .map((folder) => folder.replace(/(.)\/+$/, "$1"));
  return [...new Set(choices)];
}

// The folder the person last started a Cloud chat in (a folder of this Mac, which the start copies onto the
// machine, or a GitHub repository, `github:owner/name`): a page with Cloud picked starts there. Cloud's own,
// apart from This Mac's started project, so each mode comes back to its own last pick; with none yet, Cloud
// starts in This Mac's (cmux#53226: Cmd+N from a Cloud workspace named a repository the person never picked, a
// local folder's GitHub origin, or No folder). The app keeps it across launches (`newTab.remember`
// `cloudStarted`, the New Tab context's `cloudStartedProject`), as `started`: a page's own storage ends with
// the launch, so a relaunch fell back to This Mac's folder.
const CLOUD_KEY = "cmux.acpmux.newTab.cloudPick.v1";

export function isCloudPick(folder: string | undefined): folder is string {
  return /^github:[^/\s]+\/[^/\s]+$/.test(folder ?? "") || (isStartableProject(folder) && !isTemporaryFolder(folder));
}

/// The app's copy as the last New Tab context named it, for a composer with no context of its own.
let appCloudPick: string | undefined;

/// The person started a Cloud chat in `folder` (a New Tab page or a chat composer).
export function rememberCloudPick(
  folder: string | undefined,
  post?: (method: string, params: Record<string, unknown>) => Promise<unknown>,
): void {
  if (!isCloudPick(folder)) return;
  const picked = folder.replace(/(.)\/+$/, "$1");
  try {
    storage()?.setItem(CLOUD_KEY, picked);
  } catch {
    // A full or blocked store: the app's copy still names it on the next page.
  }
  appCloudPick = picked;
  void post?.("newTab.remember", { cloudStarted: picked }).catch(() => undefined);
}

/// The Cloud picks a page may start on, newest first: this run's copy, then the app's (`cloudStartedProject` in
/// the page's context, kept across launches; with none given, the last one a context named). Both, not the first
/// alone: a run's copy the host no longer lists gives way to the app's.
export function cloudPickChoices(fromApp?: string): string[] {
  if (isCloudPick(fromApp)) appCloudPick = fromApp;
  let run: string | undefined;
  try {
    run = storage()?.getItem(CLOUD_KEY) ?? undefined;
    // The app's copy seeds this run's, which every page of the run shares: a chat restored after a relaunch (no
    // New Tab context of its own) reads it once any page (the prewarmed spare) had the context.
    if (!isCloudPick(run) && isCloudPick(fromApp)) storage()?.setItem(CLOUD_KEY, fromApp);
  } catch {
    run = undefined;
  }
  return [...new Set([run, appCloudPick].filter((folder): folder is string => isCloudPick(folder)))];
}

let appCloudPickAsked = false;

/// A chat page has no New Tab context, and its storage is not a New Tab page's: it asks the app for Cloud's last pick
/// once (`newTab.cloudPick`), so its composer's Cloud starts there too. A pick this page made or was given wins.
export function askAppCloudPick(
  post: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  answered?: () => void,
): void {
  if (appCloudPickAsked) return;
  appCloudPickAsked = true;
  void post("newTab.cloudPick", {})
    .then((reply) => {
      // Cloud's own agent pick (cloudAgentPick.ts), kept apart from This Mac's.
      seedCloudLastPick((reply as { cloudAgent?: unknown } | undefined)?.cloudAgent);
      const picked = (reply as { cloudStarted?: unknown } | undefined)?.cloudStarted;
      if (typeof picked !== "string" || appCloudPick !== undefined || !isCloudPick(picked)) return;
      cloudPickChoices(picked);
      answered?.();
    })
    .catch(() => undefined);
}

/// Forget the app's copy this module holds (tests: a new launch).
export function forgetAppCloudPickForTests(): void {
  appCloudPick = undefined;
  appCloudPickAsked = false;
}
