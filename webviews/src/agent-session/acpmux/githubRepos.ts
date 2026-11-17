// The person's GitHub repositories in the new chat's folder menu, for a Cloud chat (FolderPopover's
// GitHub part). Three host calls, snake_case on the wire like their neighbours:
//   github.status        {}                -> { state: ready | not_connected | unavailable, repos_scope }
//   github.connect       {}                -> { opened: true } (the host opens GitHub in the browser)
//   github.repos.list    { query }         -> { repos: [{ full_name, private, default_branch }], truncated }
// A repository picked as the chat's folder is the folder string `github:owner/name`: the composer
// carries it where a folder path goes (App.tsx `projectDraft`), and the Cloud start sends it as
// `cloud.startChat {cwd}`; the machine clones it.
//
// One small store per page (useSyncExternalStore, as cloudMachines.ts), driven by the menu's own
// events: opening the menu reads the status, Install on GitHub opens GitHub and then reads the status
// again each time the page becomes the key one (pageKey.ts), until it says ready. No timers, no polls.
import { useSyncExternalStore } from "react";
import { githubRepository } from "./githubRepository";
import { postNative } from "./native";
import { pageIsKey, watchPageKey } from "./pageKey";
import { translate } from "./i18n";
import { errorMessage } from "./transportErrors";

export type GitHubConnection = "ready" | "not_connected" | "unavailable";
export type GitHubStatus = { state: GitHubConnection; reposScope: "all" | "selected" | null };
export type GitHubRepo = { fullName: string; private: boolean; defaultBranch: string | null };

/// What the folder menu draws. `status` undefined: not read yet (nothing shows).
export type GitHubPickerState = {
  status?: GitHubStatus;
  /// The repositories read for `query` (undefined: none read yet).
  repos?: readonly GitHubRepo[];
  query: string | null;
  truncated: boolean;
  loading: boolean;
  /// `github.repos.list` failed with anything but `github.not_connected`: one line with Retry.
  error?: string;
  /// Install on GitHub opened GitHub: the card waits until the status says ready.
  waiting: boolean;
  /// `github.connect` was refused: the host's words, under the card's button.
  connectError?: string;
};

/// The folder menu's handle on the store (a gallery or test passes its own).
export type GitHubPicker = {
  state: GitHubPickerState;
  /// The menu opened: read the status (and the repositories, once it is ready).
  onOpen(): void;
  /// Install on GitHub, or Choose more repositories…: the host opens GitHub.
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
  const raw = (reply ?? {}) as { state?: unknown; repos_scope?: unknown };
  const state: GitHubConnection = raw.state === "ready" || raw.state === "not_connected" ? raw.state : "unavailable";
  const reposScope = raw.repos_scope === "all" || raw.repos_scope === "selected" ? raw.repos_scope : null;
  return { state, reposScope };
}

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

const INITIAL: GitHubPickerState = { query: null, truncated: false, loading: false, waiting: false };

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// The store: `call` is the host (postNative), `watchKey`/`isKey` the page's key state (pageKey.ts).
export function createGitHubPicker(
  call: Call = postNative,
  watchKey: (run: () => void) => () => void = watchPageKey,
  isKey: () => boolean = pageIsKey,
) {
  let state = INITIAL;
  const listeners = new Set<() => void>();
  // Each read's turn: an answer to an older read than the latest changes nothing.
  let statusTurn = 0;
  let reposTurn = 0;
  let unwatch: (() => void) | undefined;
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
      },
      (error: unknown) => {
        if (turn !== reposTurn) return;
        if ((error as { code?: unknown } | null)?.code === "github.not_connected") {
          set({ loading: false, repos: undefined, status: { state: "not_connected", reposScope: null } });
          return;
        }
        set({ loading: false, error: errorMessage(error).trim() || translate("composer.githubReposFailed") });
      },
    );
  };
  const readStatus = () => {
    const turn = ++statusTurn;
    call("github.status", {}).then(
      (reply) => {
        if (turn !== statusTurn) return;
        const status = githubStatusFromReply(reply);
        const ready = status.state === "ready";
        if (ready || status.state === "unavailable") stopWaiting();
        set({ status, ...(ready || status.state === "unavailable" ? { waiting: false } : {}) });
        if (ready && (state.repos === undefined || state.error !== undefined)) listRepos(state.query);
      },
      () => {
        // A host that does not serve it (an older app) or refused it: no GitHub part at all.
        if (turn !== statusTurn) return;
        stopWaiting();
        set({ status: { state: "unavailable", reposScope: null }, waiting: false });
      },
    );
  };
  const picker = {
    snapshot: () => state,
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    open: readStatus,
    connect() {
      set({ connectError: undefined });
      call("github.connect", {}).then(
        () => {
          set({ waiting: true });
          // Back from the browser: the page becomes the key one again, and the status is read.
          unwatch ??= watchKey(() => {
            if (isKey()) readStatus();
          });
        },
        (error: unknown) =>
          set({ connectError: errorMessage(error).trim() || translate("composer.githubConnectFailed") }),
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
  if (!pageStore) pageStore = createGitHubPicker();
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
