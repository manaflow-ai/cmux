// The Messages mirror page's wire (cmux-page://cmux.imessage/): the daemon's read-only `imessage.*`
// ops over this Mac's Messages database, relayed by the app as `cmux.imessage.*`. The shapes are the
// serde snake_case shapes of the `cmux-imessage` reader (cmux-tui/crates/cmux-imessage, #32891).
// Read only: the page sends nothing to Messages.

export const ImessageOps = {
  /** `{}` → `ImessageStatus`. Never fails for a known state; it reports it. */
  status: "cmux.imessage.status",
  /** `{limit?}` → `{threads: Thread[]}`, newest first. */
  threads: "cmux.imessage.threads.list",
  /** `{chat_id, before_rowid?, limit?}` → `{messages: Message[]}`, oldest first. */
  messages: "cmux.imessage.messages.list",
  /** The daemon's `imessage-changed` event. */
  changed: "cmux.imessage.changed",
  /** Opens System Settings > Privacy & Security > Full Disk Access (the app's own route, no daemon). */
  openFullDiskAccess: "cmux.imessage.privacy.open",
} as const;

/** The app's native op that runs one allowlisted action (`openSettings`). */
export const ACTION_RUN = "cmux.app.action.run";

/** How many messages one page of a conversation asks for. */
export const MESSAGE_PAGE = 100;
/** How many threads the list asks for. */
export const THREAD_LIMIT = 200;

export type ImessageAccess = "off" | "ok" | "not_permitted" | "missing" | "schema" | "error";

export interface ImessageStatus {
  enabled: boolean;
  access: ImessageAccess;
  message?: string;
  latest_rowid?: number;
  database_path?: string;
}

export interface ThreadPreview {
  rowid: number;
  text?: string | null;
  is_from_me: boolean;
  sender?: string | null;
  date_ms?: number | null;
  has_attachments: boolean;
}

export interface Thread {
  chat_id: number;
  guid: string;
  title: string;
  display_name?: string | null;
  is_group: boolean;
  service?: string | null;
  participants: string[];
  last_message?: ThreadPreview | null;
}

export interface Attachment {
  name?: string | null;
  mime_type?: string | null;
}

export interface Message {
  rowid: number;
  guid: string;
  chat_id: number;
  sender?: string | null;
  is_from_me: boolean;
  date_ms?: number | null;
  text?: string | null;
  attachments: Attachment[];
}

export interface ImessageChanged {
  revision: number;
  chat_ids: number[];
  latest_rowid: number;
  status_changed: boolean;
  /** The relay's own `{resync: true}` after a reconnect or lost events: re-read everything. */
  resync?: boolean;
}

/** The daemon's refusal codes for the list ops, as the relay hands them on (`cmux.` + code). */
export const ImessageErrors = {
  disabled: "imessage_disabled",
  notPermitted: "imessage_not_permitted",
  unavailable: "imessage_unavailable",
} as const;
