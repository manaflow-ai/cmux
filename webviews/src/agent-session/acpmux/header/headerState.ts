import { useSyncExternalStore } from "react";

/// What the chat header shows from the chat's tab (CmuxNextAgentPane AgentPaneHeaderState): the pin the
/// "..." menu's labels read, whether the panes beside the chat show ([+] New tab reads Hide tabs), and
/// the header splits whose toggle is lit because the split it opened is open (cx-00n1). The page reads it
/// with `pane.tabState` when a chat opens; the App pushes `headerState` whenever it changes, so a split
/// the user closes from its own tab turns its button off at once.
/// The chat folder's pull request (CmuxNextAgentPane AgentPanePullRequest, cx-tcwj): its checks are
/// summed `failing`, `pending`, `passing` or `none`.
export interface HeaderPullRequest {
  readonly url: string;
  readonly number: number;
  readonly title: string;
  /// `open`, `draft`, `merged` or `closed`.
  readonly state: string;
  /// `approved`, `changes_requested`, `review_required`, or empty.
  readonly review: string;
  /// `mergeable`, `conflicting`, or empty while GitHub works it out.
  readonly mergeable: string;
  readonly checks: { readonly state: string; readonly passed: number; readonly total: number };
  /// Each check, failed first (cx-ncc.77.1): `passed`, `failed` or `pending`, with its run's https page.
  readonly checkList: readonly HeaderCheck[];
}

export interface HeaderCheck {
  readonly name: string;
  readonly state: string;
  readonly url?: string;
}

export interface HeaderState {
  readonly pinned: boolean;
  readonly sideTabs: boolean;
  /// App action ids (`splitRight`, `splitBrowserRight`).
  readonly lit: readonly string[];
  /// The "..." menu offers Move to Floating Chat (Start Agent's floating chat is on, cx-b9qi).
  readonly floatingChat: boolean;
  /// The header offers the session side rail (Debug Settings `agent.sessionRail`, cx-ncc.101).
  readonly sessionRail: boolean;
  /// Panels open as tabs on the right (Debug Settings `agentChat.panelTabs`): while panes show beside
  /// the chat, the header drops its quick-action buttons into "..." and the right side's tab strip
  /// is where new tabs go.
  readonly panelTabs: boolean;
  /// The chip beside the tools; the App sends `null` when the chat's folder has none.
  readonly pullRequest?: HeaderPullRequest;
  /// Rises with each change the App sees: a `pane.tabState` reply that arrives after a newer push is dropped.
  readonly version: number;
}

let current: HeaderState = {
  pinned: false,
  sideTabs: false,
  lit: [],
  floatingChat: false,
  sessionRail: false,
  panelTabs: false,
  version: 0,
};
const listeners = new Set<() => void>();

/// The App's state (a `pane.tabState` reply or a `headerState` push); fields it leaves out keep their value.
export function setHeaderState(value: unknown): void {
  const raw = (value ?? {}) as {
    pinned?: unknown;
    sideTabs?: unknown;
    lit?: unknown;
    floatingChat?: unknown;
    sessionRail?: unknown;
    panelTabs?: unknown;
    pullRequest?: unknown;
    version?: unknown;
  };
  const version = typeof raw.version === "number" ? raw.version : current.version;
  if (version < current.version) return;
  const next: HeaderState = {
    pinned: typeof raw.pinned === "boolean" ? raw.pinned : current.pinned,
    sideTabs: typeof raw.sideTabs === "boolean" ? raw.sideTabs : current.sideTabs,
    lit: Array.isArray(raw.lit) ? raw.lit.filter((id): id is string => typeof id === "string") : current.lit,
    floatingChat: typeof raw.floatingChat === "boolean" ? raw.floatingChat : current.floatingChat,
    sessionRail: typeof raw.sessionRail === "boolean" ? raw.sessionRail : current.sessionRail,
    panelTabs: typeof raw.panelTabs === "boolean" ? raw.panelTabs : current.panelTabs,
    pullRequest: "pullRequest" in raw ? pullRequestOf(raw.pullRequest) : current.pullRequest,
    version,
  };
  if (JSON.stringify(next) === JSON.stringify(current)) return;
  current = next;
  for (const listener of listeners) listener();
}

/// The App's pull request, if it has the fields the chip reads and an https link.
function pullRequestOf(value: unknown): HeaderPullRequest | undefined {
  const raw = (value ?? {}) as Partial<Record<keyof HeaderPullRequest, unknown>>;
  const checks = (raw.checks ?? {}) as Partial<Record<keyof HeaderPullRequest["checks"], unknown>>;
  if (typeof raw.url !== "string" || !raw.url.startsWith("https://") || typeof raw.number !== "number")
    return undefined;
  const text = (value: unknown) => (typeof value === "string" ? value : "");
  return {
    url: raw.url,
    number: raw.number,
    title: text(raw.title),
    state: typeof raw.state === "string" ? raw.state : "open",
    review: text(raw.review),
    mergeable: text(raw.mergeable),
    checkList: (Array.isArray(raw.checkList) ? raw.checkList : []).flatMap((check: unknown): HeaderCheck[] => {
      const row = (check ?? {}) as Record<string, unknown>;
      if (typeof row.name !== "string") return [];
      const url = typeof row.url === "string" && row.url.startsWith("https://") ? row.url : undefined;
      return [{ name: row.name, state: text(row.state), ...(url ? { url } : {}) }];
    }),
    checks: {
      state: typeof checks.state === "string" ? checks.state : "none",
      passed: typeof checks.passed === "number" ? checks.passed : 0,
      total: typeof checks.total === "number" ? checks.total : 0,
    },
  };
}

export const headerState = (): HeaderState => current;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The live header state.
export const useHeaderState = (): HeaderState => useSyncExternalStore(subscribe, headerState, headerState);
