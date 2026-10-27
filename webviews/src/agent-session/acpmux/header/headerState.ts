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
  readonly checks: {
    readonly state: string;
    readonly passed: number;
    readonly total: number;
    /// How many of the failing checks also fail at the base branch's tip, so the pull request did
    /// not break them. Absent or 0 means "none claimed", not "none exist": a single-link
    /// `gh pr view` cannot read the base's checks at all.
    readonly failingOnBase?: number;
  };
  /// Each check, failed first (cx-ncc.77.1): `passed`, `failed` or `pending`, with its run's https page.
  readonly checkList: readonly HeaderCheck[];
}

export interface HeaderCheck {
  readonly name: string;
  readonly state: string;
  readonly url?: string;
  /// This check fails the same way at the base branch's tip (AgentPanePullRequest `onBase`). Absent
  /// means "nothing claimed", not "it is this pull request's": a `gh pr view` cannot read the base.
  readonly onBase?: boolean;
}

export interface HeaderMoveTarget {
  readonly id: string;
  readonly label: string;
  readonly status?: string;
}

export interface HeaderState {
  readonly pinned: boolean;
  readonly sideTabs: boolean;
  /// App action ids (`splitRight`, `splitBrowserRight`).
  readonly lit: readonly string[];
  /// The "..." menu offers Move to Floating Chat (Start Agent's floating chat is on, cx-b9qi).
  readonly floatingChat: boolean;
  /// Debug Settings' Side sessions (/btw) is on (`agentPane.debug.sideSessions`): the composer offers `/btw`
  /// (aside/sideSessions.ts). Off until the app sends it; an update that leaves it out keeps its value.
  readonly sideSessions: boolean;
  /// The header offers the Inspector (Debug Settings `agent.inspector`, inspector/ChatInspector.tsx).
  readonly inspector: boolean;
  /// Browser opens the chat's page and Preview is no button of its own (Debug Settings
  /// `agentChat.browserOpensPreview`, on by default; off: separate Preview and Browser).
  readonly browserOpensPreview: boolean;
  /// The chip beside the tools; the App sends `null` when the chat's folder has none.
  readonly pullRequest?: HeaderPullRequest;
  /// The Cloud moves the chat's right-click menu offers now (`cloudMove`, `cloudBringBack`): the
  /// composer's picker offers the same. Only a `pane.tabState` reply carries it; a push keeps it.
  readonly moves: readonly string[];
  /// Eligible Cloud machine targets for the title menu. The host validates ids again on dispatch.
  readonly moveTargets: readonly HeaderMoveTarget[];
  /// Rises with each change the App sees: a `pane.tabState` reply that arrives after a newer push is dropped.
  readonly version: number;
}

/// When the App first reported each pull request's current state (epoch ms), so a state the chat
/// set itself (a close) can tell an older read from a newer one.
const stateSince = new Map<string, { state: string; at: number }>();

/// When the App first reported pull request `url` in the state it has now.
export const pullRequestStateSince = (url: string): number | undefined => stateSince.get(url)?.at;

let current: HeaderState = {
  pinned: false,
  sideTabs: false,
  lit: [],
  floatingChat: false,
  sideSessions: false,
  inspector: false,
  browserOpensPreview: true,
  moves: [],
  moveTargets: [],
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
    sideSessions?: unknown;
    inspector?: unknown;
    browserOpensPreview?: unknown;
    pullRequest?: unknown;
    moves?: unknown;
    moveTargets?: unknown;
    version?: unknown;
  };
  const version = typeof raw.version === "number" ? raw.version : current.version;
  if (version < current.version) return;
  const next: HeaderState = {
    pinned: typeof raw.pinned === "boolean" ? raw.pinned : current.pinned,
    sideTabs: typeof raw.sideTabs === "boolean" ? raw.sideTabs : current.sideTabs,
    lit: Array.isArray(raw.lit) ? raw.lit.filter((id): id is string => typeof id === "string") : current.lit,
    floatingChat: typeof raw.floatingChat === "boolean" ? raw.floatingChat : current.floatingChat,
    sideSessions: typeof raw.sideSessions === "boolean" ? raw.sideSessions : current.sideSessions,
    inspector: typeof raw.inspector === "boolean" ? raw.inspector : current.inspector,
    browserOpensPreview:
      typeof raw.browserOpensPreview === "boolean" ? raw.browserOpensPreview : current.browserOpensPreview,
    pullRequest: "pullRequest" in raw ? pullRequestOf(raw.pullRequest) : current.pullRequest,
    moves: Array.isArray(raw.moves) ? raw.moves.filter((id): id is string => typeof id === "string") : current.moves,
    moveTargets: Array.isArray(raw.moveTargets)
      ? raw.moveTargets.flatMap((target: unknown): HeaderMoveTarget[] => {
          const row = (target ?? {}) as Record<string, unknown>;
          if (typeof row.id !== "string" || !row.id || typeof row.label !== "string" || !row.label) return [];
          return [
            {
              id: row.id,
              label: row.label,
              ...(typeof row.status === "string" && row.status ? { status: row.status } : {}),
            },
          ];
        })
      : current.moveTargets,
    version,
  };
  if (JSON.stringify(next) === JSON.stringify(current)) return;
  const pr = next.pullRequest;
  if (pr && stateSince.get(pr.url)?.state !== pr.state) stateSince.set(pr.url, { state: pr.state, at: Date.now() });
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
      return [
        {
          name: row.name,
          state: text(row.state),
          ...(url ? { url } : {}),
          ...(row.onBase === true ? { onBase: true } : {}),
        },
      ];
    }),
    checks: {
      state: typeof checks.state === "string" ? checks.state : "none",
      passed: typeof checks.passed === "number" ? checks.passed : 0,
      total: typeof checks.total === "number" ? checks.total : 0,
      failingOnBase: typeof checks.failingOnBase === "number" ? checks.failingOnBase : 0,
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
