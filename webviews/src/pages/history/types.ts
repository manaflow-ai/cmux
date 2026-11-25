// Wire types of the `cmux.history/1` namespace (plans/cmux-next/react-pages.md 2.3). The Rust
// `cmux-history` crate is the source of truth (serde snake_case); these mirror it until the pane
// protocol generator emits them from the IR.

export type HistoryKind = "page" | "location" | "closed" | "command" | "agent";

export const HISTORY_KINDS: readonly HistoryKind[] = ["page", "location", "closed", "command", "agent"];

export type HistoryRange = "hour" | "today" | "week" | "month" | "all";

export const HISTORY_RANGES: readonly HistoryRange[] = ["hour", "today", "week", "month", "all"];

export type ClosedKind = "terminal_tab" | "browser_tab" | "conversation_tab" | "screen" | "workspace";

/** One row of the merged timeline. Optional fields are absent when the kind has no such fact. */
export interface HistoryEntry {
  /** Qualified: `<kind>:<machine or profile>:<id>`. */
  id: string;
  kind: HistoryKind;
  at_ms: number;
  title: string;
  /** URL, directory or workspace, shown under the title. */
  detail?: string;
  /** Machine name for machine facts; absent for local-only entries. */
  machine?: string;
  workspace?: string;
  /** False while the owning machine is not connected: greyed, restore refused. */
  available: boolean;
  /** Location: the trail cursor. */
  current?: boolean;
  /** Agent: the session has not ended. */
  running?: boolean;
  url?: string;
  profile?: string;
  closed_kind?: ClosedKind;
  cwd?: string;
  command?: string;
  exit_code?: number;
  session_id?: string;
  provider?: string;
}

export interface HistoryListParams {
  kinds?: HistoryKind[];
  text?: string;
  range?: HistoryRange;
  limit?: number;
  cursor?: string;
}

export interface HistoryListResult {
  entries: HistoryEntry[];
  next_cursor?: string;
  revision: number;
  /** The asked kinds whose entries are not complete yet (the owner's fold of the session journal is
   * still behind): `entries` is what it has so far. The page shows that and asks again until the field
   * is absent; `cmux.history.changed` only makes it sooner (it comes only when an entry of the kind changes). */
  pending_kinds?: HistoryKind[];
}

export interface HistoryChanged {
  revision: number;
  kinds: HistoryKind[];
}

/** Canonical op names (decision ONE-CATALOG: the daemon's short wire names are aliases). */
export const HistoryOps = {
  list: "cmux.history.entries.list",
  remove: "cmux.history.entries.remove",
  removeSite: "cmux.history.site.remove",
  clear: "cmux.history.clear",
  changed: "cmux.history.changed",
  /** The app's cookie backups (an agent's cookie clear in a WebKit tab keeps one): `{backups}`. */
  cookieBackupsList: "cmux.history.cookie_backups.list",
  /** Deletes backups for good after the app's own confirmation: `{ids}` -> `{confirmed, deleted}`. */
  cookieBackupsDelete: "cmux.history.cookie_backups.delete",
} as const;

/** One cookie backup the app keeps on this Mac (decision D3 on cmux#13742); never a cookie value. */
export interface CookieBackup {
  /** The restore id (`app:<32 hex>`). */
  id: string;
  /** The host whose cookies the clear removed; absent when this Mac's key no longer opens it. */
  site?: string;
  created_at_ms: number;
}

export interface CookieBackupsDeleted {
  /** False when the person cancelled the app's confirmation. */
  confirmed: boolean;
  deleted?: number;
}

/** The native UI op that runs a registry action in the hosting app (react-pages.md 1.3). */
export const ACTION_RUN = "cmux.app.action.run";
/** The native UI op for the pasteboard, when the page origin cannot use the async clipboard. */
export const CLIPBOARD_WRITE = "cmux.app.clipboard.write";
