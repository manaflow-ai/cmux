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
// events: Add project opening reads the status, and the repositories once it is ready (nothing is read
// before the person asks for them, cmux#53226; the repositories stay as read), Connect to GitHub opens
// GitHub and then reads the status again each time the page becomes the key one (pageKey.ts), until
// it says ready. No timers, no polls.
import { useSyncExternalStore } from "react";
import { githubRepository } from "./githubRepository";
import { postNative } from "./native";
import { pageIsKey, watchPageKey } from "./pageKey";
import { translate } from "./i18n";
import { errorMessage } from "./transportErrors";

export type GitHubConnection = "ready" | "not_connected" | "unavailable";
/// Why GitHub is `unavailable`: signed out of the Cloud service, no GitHub App on this Cloud service, or the
/// check did not answer (an older host sends no reason: read as `unreachable`).
export type GitHubUnavailableReason = "signed_out" | "not_configured" | "not_allowed" | "unreachable";
export type GitHubStatus = {
  state: GitHubConnection;
  reposScope: "all" | "selected" | null;
  /// Only while `unavailable`.
  reason?: GitHubUnavailableReason;
  /// Only while `not_connected`, when Connect needs more than its title: the host's words for why (a suspended or
  /// uninstalled App, a link in progress, a connection in error, a link the API refused), the Connect row's second line.
  message?: string;
  pendingApproval?: boolean;
  connecting?: boolean;
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
  connecting?: boolean;
  rateLimited?: boolean;
  retryAfter?: number;
  /// The repository the person wanted when Connect (or Choose more repositories…) started: what they typed, else the
  /// chosen folder's (`owner/name`). Kept here only, never sent to the host. The next repository list after GitHub
  /// changed answers it: `returned` when listed, `missing` when not (Leo 2026-11-25, github-setup-handoffs).
  wanted?: string;
  /// The wanted repository came back listed: the folder menu picks it once (``GitHubPicker/onTakeReturned``).
  returned?: string;
  /// The wanted repository is still not shared with the app: the GitHub step says how to add it.
  missing?: string;
};

/// The folder menu's handle on the store (a gallery or test passes its own).
export type GitHubPicker = {
  state: GitHubPickerState;
  /// The menu opened: read the status (and the repositories, once it is ready).
  onOpen(): void;
  /// Connect to GitHub, or Choose more repositories…: the host opens GitHub. `want`: the repository the person is
  /// after (typed or chosen; `owner/name`, `github:owner/name` or a github.com URL), picked once it comes back.
  onConnect(want?: string): void;
  /// The folder menu picked `returned`: forget it.
  onTakeReturned?(): void;
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
  const raw = (reply ?? {}) as {
    state?: unknown;
    repos_scope?: unknown;
    reason?: unknown;
    message?: unknown;
    pending_approval?: unknown;
    connecting?: unknown;
  };
  const state: GitHubConnection = raw.state === "ready" || raw.state === "not_connected" ? raw.state : "unavailable";
  const reposScope = raw.repos_scope === "all" || raw.repos_scope === "selected" ? raw.repos_scope : null;
  if (state === "not_connected") {
    const message = typeof raw.message === "string" ? raw.message.trim() : undefined;
    return {
      state,
      reposScope,
      ...(message ? { message } : {}),
      ...(raw.connecting === true ? { connecting: true } : {}),
      ...(raw.pending_approval === true ? { pendingApproval: true } : {}),
    };
  }
  if (state !== "unavailable") return { state, reposScope };
  const reason: GitHubUnavailableReason =
    raw.reason === "signed_out" || raw.reason === "not_configured" || raw.reason === "not_allowed"
      ? raw.reason
      : "unreachable";
  return { state, reposScope, reason };
}

/// A `github.connect` refusal that says why GitHub is unavailable.
const CONNECT_REFUSAL_REASON: Record<string, GitHubUnavailableReason> = {
  "github.signed_out": "signed_out",
  "github.not_configured": "not_configured",
  "github.not_allowed": "not_allowed",
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

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// How a Cloud start card's Connect GitHub ended (``createGitHubPicker`` `connectRepo`).
export type ConnectOutcome = "opened" | "connected" | "failed" | "busy";

/// `owner/name` from a Cloud start's repository (`owner/name`, `github:owner/name` or a github.com URL); undefined for
/// anything else, so only a repository name reaches the host's `github.connect`.
export function githubFullName(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const text = value
    .trim()
    .replace(/^github:/i, "")
    .replace(/^(?:https?:\/\/|git@)github\.com[/:]/i, "")
    .replace(/\.git$/i, "")
    .replace(/\/+$/, "");
  return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/.test(text) && !/\/\.{1,2}$/.test(text)
    ? text
    : undefined;
}

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
) {
  let state = INITIAL;
  const listeners = new Set<() => void>();
  // Each read's turn: an answer to an older read than the latest changes nothing.
  let statusTurn = 0;
  let reposTurn = 0;
  let unwatch: (() => void) | undefined;
  // A status read is out: an open while it is waits for that answer rather than asking twice.
  let statusOut = false;
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
  // A list read after GitHub changed (or the page came back from GitHub) answers `wanted`; a list read for any
  // other reason (the menu opening before Connect) does not.
  let checksWanted = false;
  const settleWanted = (wanted: string, repos: readonly GitHubRepo[], truncated: boolean, query: string | null) => {
    const found = repos.find((repo) => repo.fullName.toLowerCase() === wanted.toLowerCase());
    if (found) {
      checksWanted = false;
      set({ wanted: undefined, missing: undefined, returned: found.fullName });
    } else if (truncated && query !== wanted) {
      listRepos(wanted); // a page that stops short: ask for the repository by name before saying it's missing
    } else {
      checksWanted = false;
      set({ wanted: undefined, missing: wanted });
    }
  };
  const listRepos = (query: string | null) => {
    const turn = ++reposTurn;
    set({ loading: true, error: undefined, rateLimited: undefined, retryAfter: undefined, query });
    call("github.repos.list", { query }).then(
      (reply) => {
        if (turn !== reposTurn) return;
        const { repos, truncated } = githubReposFromReply(reply);
        set({ repos, truncated, loading: false });
        if (state.wanted && !state.waiting && checksWanted) settleWanted(state.wanted, repos, truncated, query);
      },
      (error: unknown) => {
        if (turn !== reposTurn) return;
        if ((error as { code?: unknown } | null)?.code === "github.not_connected") {
          set({ loading: false, repos: undefined, status: { state: "not_connected", reposScope: null } });
          return;
        }
        const failure = error as { code?: unknown; details?: { retry_after?: unknown } } | null;
        const rateLimited = failure?.code === "github.rate_limited" || failure?.code === "rate_limited";
        const retry = failure?.details?.retry_after;
        set({
          loading: false,
          error: errorMessage(error).trim() || translate("composer.githubReposFailed"),
          ...(rateLimited ? { rateLimited } : {}),
          ...(rateLimited && typeof retry === "number" && Number.isFinite(retry) && retry > 0
            ? { retryAfter: retry }
            : {}),
        });
      },
    );
  };
  // `relist`: list the repositories again even when some are shown (the installation's repositories changed).
  const readStatus = (relist = false) => {
    statusOut = true;
    const turn = ++statusTurn;
    call("github.status", {}).then(
      (reply) => {
        if (turn !== statusTurn) return;
        statusOut = false;
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
        // A list still out for the same words (an earlier open's, Add project opened again under it) answers this
        // read too: a second would drop the first and keep the Loading row up longer (cmux#53226).
        const listing = state.loading && !relist;
        if (ready && !listing && (relist || state.repos === undefined || state.error !== undefined))
          listRepos(state.query);
      },
      () => {
        // A host that does not serve it (an older app) or refused it: GitHub can't be reached.
        if (turn !== statusTurn) return;
        statusOut = false;
        stopWaiting();
        set({ status: { state: "unavailable", reposScope: null, reason: "unreachable" }, waiting: false });
      },
    );
  };
  // One-shot listeners for the next change (`afterChange`): a Cloud start card's Retry once its Connect finished.
  const afterChanges = new Set<() => void>();
  // The app finished a connection (or a Reconfigure changed it): a menu that read the status reads it again, and its
  // repositories with it, with no restart and no click.
  watchChanged(() => {
    if (state.wanted) checksWanted = true;
    if (state.status !== undefined || state.wanted) readStatus(true);
    const runs = [...afterChanges];
    afterChanges.clear();
    for (const run of runs) run();
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
      if (!statusOut) readStatus();
    },
    connect(want?: string) {
      if (state.connecting) return;
      const wanted = githubFullName(want);
      checksWanted = false;
      set({ connectError: undefined, connecting: true, wanted, missing: undefined, returned: undefined });
      // The wanted repository goes to the host too: GitHub's page opens for its owner, and a connection that already
      // covers it answers `opened: false` with nothing to open.
      call("github.connect", wanted ? { repo: wanted } : {}).then(
        (reply) => {
          set({ connecting: false });
          // Already connected (the host found it so as it re-read the status): read it here too.
          if ((reply as { opened?: unknown } | null)?.opened === false) {
            if (state.wanted) checksWanted = true;
            readStatus(state.wanted !== undefined);
            return;
          }
          waitingFrom = statusKey(state.status);
          set({ waiting: true });
          // Back from the browser: the page becomes the key one again, and the status is read.
          unwatch ??= watchKey(() => {
            if (!isKey()) return;
            // Choose more repositories… from a ready list: the status stays ready, so the list is read again for the
            // wanted repository (GitHub's settings page may not hand back to the app).
            if (state.wanted) checksWanted = true;
            readStatus(state.wanted !== undefined);
          });
        },
        (error: unknown) => {
          const code = (error as { code?: unknown } | null)?.code;
          const reason = typeof code === "string" ? CONNECT_REFUSAL_REASON[code] : undefined;
          set({
            connecting: false,
            connectError: errorMessage(error).trim() || translate("composer.githubConnectFailed"),
            // The refusal says why GitHub is unavailable: the row's words follow it.
            ...(reason && state.status?.state === "unavailable" ? { status: { ...state.status, reason } } : {}),
          });
        },
      );
    },
    /// A Cloud start card's Connect GitHub for `repo` (`owner/name`, #55104): the host asks the API for that
    /// repository, which reuses a connection that covers it (`connected`) or opens GitHub's page (`opened`), whose
    /// return the app finishes. Resolves how it ended; a refusal is shown as `connectError`, as `connect`'s.
    connectRepo(repo: string | undefined): Promise<ConnectOutcome> {
      if (state.connecting) return Promise.resolve("busy");
      set({ connectError: undefined, connecting: true });
      return call("github.connect", repo ? { repo } : {}).then(
        (reply) => {
          set({ connecting: false });
          if ((reply as { opened?: unknown } | null)?.opened === false) {
            readStatus(true);
            return "connected";
          }
          return "opened";
        },
        (error: unknown) => {
          set({
            connecting: false,
            connectError: errorMessage(error).trim() || translate("composer.githubConnectFailed"),
          });
          return "failed";
        },
      );
    },
    /// Runs `run` once, the next time the app says GitHub changed (a connect it finished); returns the cancel.
    takeReturned() {
      if (state.returned !== undefined) set({ returned: undefined });
    },
    afterChange(run: () => void): () => void {
      afterChanges.add(run);
      return () => void afterChanges.delete(run);
    },
    search: listRepos,
    retry: () => listRepos(state.query),
  };
  return picker;
}

export type GitHubPickerStore = ReturnType<typeof createGitHubPicker>;

let pageStore: GitHubPickerStore | undefined;

/// The page's one store (the folder menu's and every Cloud start card's).
export function gitHubPickerStore(): GitHubPickerStore {
  return pagePicker();
}

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
    onTakeReturned: picker.takeReturned,
  };
}
