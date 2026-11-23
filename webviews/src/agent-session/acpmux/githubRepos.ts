// The person's GitHub repositories in the new chat's folder menu, for a Cloud chat (FolderPopover's
// GitHub part). Three host calls, snake_case on the wire like their neighbours:
//   github.status        {}                -> { state: ready | not_connected | unavailable, repos_scope,
//                                              reason?: signed_out | not_configured | unreachable }
//   github.connect       {}                -> { opened: true } (the host opens GitHub, or its sign-in, in the
//                                              browser) | { opened: false } (already connected); refused with
//                                              github.signed_out | github.not_configured | github.unavailable |
//                                              github.connect_failed and a short message
//   github.repos.list    { query }         -> { repos: [{ full_name, private, default_branch }], truncated }
// A repository picked as the chat's folder is the folder string `github:owner/name`: the composer
// carries it where a folder path goes (App.tsx `projectDraft`), and the Cloud start sends it as
// `cloud.startChat {cwd}`; the machine clones it.
//
// One small store per page (useSyncExternalStore, as cloudMachines.ts), driven by the menu's own
// events: opening the menu reads the status, Connect to GitHub opens GitHub and then reads the status
// again each time the page becomes the key one (pageKey.ts), until it says ready. No timers, no polls.
import { useSyncExternalStore } from "react";
import { githubRepository } from "./githubRepository";
import { postNative } from "./native";
import { pageIsKey, watchPageKey } from "./pageKey";
import { translate } from "./i18n";
import { errorMessage } from "./transportErrors";

export type GitHubConnection = "ready" | "not_connected" | "unavailable";
/// Why GitHub is `unavailable`: signed out of the Cloud service, no GitHub App on this Cloud service, or the
/// check did not answer (an older host sends no reason: read as `unreachable`).
export type GitHubUnavailableReason = "signed_out" | "not_configured" | "unreachable";
export type GitHubStatus = {
  state: GitHubConnection;
  reposScope: "all" | "selected" | null;
  /// Only while `unavailable`.
  reason?: GitHubUnavailableReason;
  /// Only while `not_connected`, when Connect needs more than its title: the host's words for why (a suspended or
  /// uninstalled App, a link in progress, a connection in error, a link the API refused), the Connect row's second line.
  message?: string;
};
export type GitHubRepo = { fullName: string; private: boolean; defaultBranch: string | null };

/// What the folder menu draws. `status` undefined: not read yet (nothing shows); `not_connected`, or
/// `unavailable` because signed out: one Connect to GitHub row whose click connects (the host opens the
/// install page, or sign-in), its failure on that row, else the status's own `message` (why Connect is needed again). Any other `unavailable` shows no row.
export type GitHubPickerState = {
  status?: GitHubStatus;
  /// The repositories read for `query` (undefined: none read yet).
  repos?: readonly GitHubRepo[];
  query: string | null;
  truncated: boolean;
  loading: boolean;
  /// `github.repos.list` failed with anything but `github.not_connected`: one line with Retry.
  error?: string;
  /// Connect to GitHub opened GitHub: the status is read again each time the page is back, until it
  /// says ready. Not drawn: GitHub's own page is the one wait (#46018).
  waiting: boolean;
  /// `github.connect` was refused: the host's words, the Connect to GitHub row's second line.
  connectError?: string;
};

/// The folder menu's handle on the store (a gallery or test passes its own).
export type GitHubPicker = {
  state: GitHubPickerState;
  /// The menu opened: read the status (and the repositories, once it is ready).
  onOpen(): void;
  /// Connect to GitHub, or Choose more repositories…: the host opens GitHub.
  onConnect(): void;
  /// Read the repositories again for `query` (Enter on a search the loaded page has no match for).
  onSearch(query: string | null): void;
  onRetry(): void;
};

/// A chosen repository as the composer's folder.
export const GITHUB_FOLDER_PREFIX = "github:";

export function githubFolder(fullName: string): string {
  return GITHUB_FOLDER_PREFIX + fullName;
}

/// `owner/name` of a `github:owner/name` folder; undefined for any other folder.
export function githubFolderRepo(folder: string | undefined): string | undefined {
  if (!folder?.startsWith(GITHUB_FOLDER_PREFIX)) return undefined;
  const name = folder.slice(GITHUB_FOLDER_PREFIX.length);
  // Only the short identity: never a URL or a path a host would read as something else.
  return githubRepository(name) === name ? name : undefined;
}

export function githubStatusFromReply(reply: unknown): GitHubStatus {
  const raw = (reply ?? {}) as { state?: unknown; repos_scope?: unknown; reason?: unknown; message?: unknown };
  const state: GitHubConnection = raw.state === "ready" || raw.state === "not_connected" ? raw.state : "unavailable";
  const reposScope = raw.repos_scope === "all" || raw.repos_scope === "selected" ? raw.repos_scope : null;
  if (state === "not_connected" && typeof raw.message === "string" && raw.message.trim() !== "") {
    return { state, reposScope, message: raw.message.trim() };
  }
  if (state !== "unavailable") return { state, reposScope };
  const reason: GitHubUnavailableReason =
    raw.reason === "signed_out" || raw.reason === "not_configured" ? raw.reason : "unreachable";
  return { state, reposScope, reason };
}

/// A `github.connect` refusal that says why GitHub is unavailable.
const CONNECT_REFUSAL_REASON: Record<string, GitHubUnavailableReason> = {
  "github.signed_out": "signed_out",
  "github.not_configured": "not_configured",
  "github.unavailable": "unreachable",
};

export function githubReposFromReply(reply: unknown): { repos: GitHubRepo[]; truncated: boolean } {
  const raw = (reply ?? {}) as { repos?: unknown; truncated?: unknown };
  const repos: GitHubRepo[] = [];
  const seen = new Set<string>();
  for (const item of Array.isArray(raw.repos) ? raw.repos : []) {
    const row = (item ?? {}) as { full_name?: unknown; private?: unknown; default_branch?: unknown };
    const fullName = githubRepository(row.full_name);
    if (!fullName || fullName !== row.full_name || seen.has(fullName)) continue;
    seen.add(fullName);
    repos.push({
      fullName,
      private: row.private === true,
      defaultBranch: typeof row.default_branch === "string" && row.default_branch ? row.default_branch : null,
    });
  }
  return { repos, truncated: raw.truncated === true };
}

/// The loaded repositories that match the menu's search: every word in `owner/name`.
export function matchingRepos(repos: readonly GitHubRepo[], query: string): GitHubRepo[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [...repos];
  return repos.filter((repo) => {
    const name = repo.fullName.toLowerCase();
    return words.every((word) => name.includes(word));
  });
}

const statusKey = (status?: GitHubStatus) => `${status?.state}:${status?.reason ?? ""}`;

const INITIAL: GitHubPickerState = { query: null, truncated: false, loading: false, waiting: false };

/// What a page last read of GitHub: the status and the repositories with no search words. The next
/// page's menu lists them on its first open (a new tab's folder menu showed none until two host
/// round trips and a GitHub read answered) and reads both again behind them, replacing them.
export type GitHubSeen = { status: GitHubStatus; repos: readonly GitHubRepo[]; truncated: boolean };
export type GitHubMemory = { read(): GitHubSeen | undefined; write(seen: GitHubSeen | undefined): void };
const NO_MEMORY: GitHubMemory = { read: () => undefined, write: () => undefined };

const SEEN_KEY = "cmux.acpmux.github.seen";
const CONNECTIONS: readonly string[] = ["ready", "not_connected", "unavailable"];

function seenFrom(value: unknown): GitHubSeen | undefined {
  const raw = (value ?? {}) as { status?: { state?: unknown }; repos?: unknown; truncated?: unknown };
  if (!raw.status || !CONNECTIONS.includes(raw.status.state as string) || !Array.isArray(raw.repos)) return undefined;
  const repos = raw.repos.filter(
    (repo): repo is GitHubRepo =>
      !!repo &&
      typeof (repo as GitHubRepo).fullName === "string" &&
      typeof (repo as GitHubRepo).private === "boolean" &&
      ((repo as GitHubRepo).defaultBranch === null || typeof (repo as GitHubRepo).defaultBranch === "string"),
  );
  return { status: raw.status as GitHubStatus, repos, truncated: raw.truncated === true };
}

/// The page's memory: localStorage, which every agent page shares (one website data store, as
/// newtab/settledCache.ts). A blocked store remembers nothing and the menu reads as before.
export const storedGitHubMemory: GitHubMemory = {
  read() {
    try {
      const text = globalThis.localStorage?.getItem(SEEN_KEY);
      return text ? seenFrom(JSON.parse(text)) : undefined;
    } catch {
      return undefined;
    }
  },
  write(seen) {
    try {
      if (seen) globalThis.localStorage?.setItem(SEEN_KEY, JSON.stringify(seen));
      else globalThis.localStorage?.removeItem(SEEN_KEY);
    } catch {
      // Storage unavailable: the next page reads GitHub as before.
    }
  },
};

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// The host's word that GitHub changed under this page (the app finished an install GitHub handed back to it, #46018):
/// `cmux-github-changed` on the window. Returns the unwatch. With no window (a store a module builds when it loads, read
/// by bun with no DOM: the gallery's manifest and a server render) there is no host to hear, and nothing to watch.
export function watchGitHubChanged(
  run: () => void,
  view: Window | undefined = typeof window === "undefined" ? undefined : window,
): () => void {
  if (!view) return () => undefined;
  view.addEventListener("cmux-github-changed", run);
  return () => view.removeEventListener("cmux-github-changed", run);
}

/// The store: `call` is the host (postNative), `watchKey`/`isKey` the page's key state (pageKey.ts).
export function createGitHubPicker(
  call: Call = postNative,
  watchKey: (run: () => void) => () => void = watchPageKey,
  isKey: () => boolean = pageIsKey,
  watchChanged: (run: () => void) => () => void = watchGitHubChanged,
  memory: GitHubMemory = NO_MEMORY,
) {
  const seen = memory.read();
  let state: GitHubPickerState = seen
    ? { ...INITIAL, status: seen.status, repos: seen.repos, truncated: seen.truncated }
    : INITIAL;
  // The status and repositories shown came from an earlier page: the first ready status lists them again.
  let stale = seen !== undefined;
  const listeners = new Set<() => void>();
  // Each read's turn: an answer to an older read than the latest changes nothing.
  let statusTurn = 0;
  let reposTurn = 0;
  let unwatch: (() => void) | undefined;
  // The status the latest Connect was clicked in: the wait ends when the status moves off it.
  let waitingFrom: string | undefined;
  const set = (next: Partial<GitHubPickerState>) => {
    state = { ...state, ...next };
    for (const listener of listeners) listener();
  };
  const stopWaiting = () => {
    unwatch?.();
    unwatch = undefined;
  };
  const listRepos = (query: string | null) => {
    const turn = ++reposTurn;
    set({ loading: true, error: undefined, query });
    call("github.repos.list", { query }).then(
      (reply) => {
        if (turn !== reposTurn) return;
        const { repos, truncated } = githubReposFromReply(reply);
        set({ repos, truncated, loading: false });
        if (query === null && state.status?.state === "ready") {
          stale = false;
          memory.write({ status: state.status, repos, truncated });
        }
      },
      (error: unknown) => {
        if (turn !== reposTurn) return;
        if ((error as { code?: unknown } | null)?.code === "github.not_connected") {
          memory.write(undefined);
          set({ loading: false, repos: undefined, status: { state: "not_connected", reposScope: null } });
          return;
        }
        set({ loading: false, error: errorMessage(error).trim() || translate("composer.githubReposFailed") });
      },
    );
  };
  // `relist`: list the repositories again even when some are shown (the installation's repositories changed).
  const readStatus = (relist = false) => {
    const turn = ++statusTurn;
    call("github.status", {}).then(
      (reply) => {
        if (turn !== statusTurn) return;
        const status = githubStatusFromReply(reply);
        const ready = status.state === "ready";
        // The wait goes on only while the browser's work is not done: still not installed, or still
        // signed out (back before the sign-in ended). Any other answer, a signed-in person's
        // not_connected included, ends it: the row is theirs to click again.
        const stays =
          state.waiting &&
          statusKey(status) === waitingFrom &&
          (status.state === "not_connected" || status.reason === "signed_out");
        if (!stays) stopWaiting();
        set({ status, ...(stays ? {} : { waiting: false }) });
        // Not connected any more: the next page shows no repositories from before.
        if (!ready) memory.write(undefined);
        if (ready && (relist || stale || state.repos === undefined || state.error !== undefined)) {
          stale = false;
          listRepos(state.query);
        }
      },
      () => {
        // A host that does not serve it (an older app) or refused it: GitHub can't be reached.
        if (turn !== statusTurn) return;
        stopWaiting();
        set({ status: { state: "unavailable", reposScope: null, reason: "unreachable" }, waiting: false });
      },
    );
  };
  // The app finished a connection (or a Reconfigure changed it): a menu that read the status reads it again, and its
  // repositories with it, with no restart and no click.
  watchChanged(() => {
    if (state.status !== undefined) readStatus(true);
  });
  const picker = {
    snapshot: () => state,
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    open() {
      // A fresh open says nothing of an earlier refusal.
      if (state.connectError !== undefined) set({ connectError: undefined });
      readStatus();
    },
    connect() {
      set({ connectError: undefined });
      call("github.connect", {}).then(
        (reply) => {
          // Already connected (the host found it so as it re-read the status): read it here too.
          if ((reply as { opened?: unknown } | null)?.opened === false) {
            readStatus();
            return;
          }
          waitingFrom = statusKey(state.status);
          set({ waiting: true });
          // Back from the browser: the page becomes the key one again, and the status is read.
          unwatch ??= watchKey(() => {
            if (isKey()) readStatus();
          });
        },
        (error: unknown) => {
          const code = (error as { code?: unknown } | null)?.code;
          const reason = typeof code === "string" ? CONNECT_REFUSAL_REASON[code] : undefined;
          set({
            connectError: errorMessage(error).trim() || translate("composer.githubConnectFailed"),
            // The refusal says why GitHub is unavailable: the row's words follow it.
            ...(reason && state.status?.state === "unavailable" ? { status: { ...state.status, reason } } : {}),
          });
        },
      );
    },
    search: listRepos,
    retry: () => listRepos(state.query),
  };
  return picker;
}

export type GitHubPickerStore = ReturnType<typeof createGitHubPicker>;

let pageStore: GitHubPickerStore | undefined;

function pagePicker(): GitHubPickerStore {
  if (!pageStore)
    pageStore = createGitHubPicker(postNative, watchPageKey, pageIsKey, watchGitHubChanged, storedGitHubMemory);
  return pageStore;
}

/// The page's one store and the folder menu's handle on it.
export function useGitHubPicker(store?: GitHubPickerStore): GitHubPicker {
  const picker = store ?? pagePicker();
  const state = useSyncExternalStore(picker.subscribe, picker.snapshot, picker.snapshot);
  return {
    state,
    onOpen: picker.open,
    onConnect: picker.connect,
    onSearch: picker.search,
    onRetry: picker.retry,
  };
}
