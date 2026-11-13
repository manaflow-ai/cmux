// Wire types of the daemon's feed client (`feed-client-v1`, plans/cmux-next/feed-page.md section 2).
// The Rust `cmux-feed-core::client` is the source of truth (serde snake_case, times in Unix ms);
// these mirror it until the pane protocol generator emits them.

export type FeedLayout = "list" | "inbox" | "needs_you";
export type FeedConnectionFilter = "feed" | "github";
export type FeedCategory = "all" | "unread" | "needs_you" | "notices";

export interface FeedViewFilter {
  connection: FeedConnectionFilter;
  category: FeedCategory;
  query?: string;
}

export interface FeedViewParams {
  layout: FeedLayout;
  filter?: FeedViewFilter;
  tz_offset_min?: number;
  limit?: number;
}

export type FeedItemState = "open" | "answered" | "cancelled" | "expired";
export type FeedPriority = "low" | "normal" | "high" | "urgent";
export type FeedPosterKind = "agent" | "harness" | "user" | "system" | "server" | "vm" | "automation" | "integration";

export interface FeedPoster {
  kind: FeedPosterKind | string;
  label: string;
  harness?: string;
}

export interface FeedContext {
  host?: string;
  workspace?: string;
  tab?: string;
  terminal?: string;
  browser_tab?: string;
  acp_session?: string;
  task?: string;
  url?: string;
}

export interface FeedAttachment {
  id: string;
  name: string;
  mime: string;
  size: number;
  /** Inline text the owner already has (a diff preview). */
  text?: string;
}

export interface FeedPosterAction {
  id: string;
  label: string;
  style?: "default" | "primary" | "destructive";
  answer?: unknown;
}

export interface FeedChoiceOption {
  id: string;
  label: string;
  description?: string;
}

export interface FeedChoiceQuestion {
  id: string;
  question: string;
  header?: string;
  options: FeedChoiceOption[];
  multi?: boolean;
  allow_other?: boolean;
}

export type FeedApproveScope = "once" | "session" | "always";

/** The kind's prompt object (feed.md 3.4), keyed by the item's `kind`. Every field is optional on
 * the wire; the page reads what its kind declares. */
export interface FeedPromptWire {
  // question
  question?: string;
  suggestions?: string[];
  multiline?: boolean;
  // choice
  questions?: FeedChoiceQuestion[];
  // approve
  action?: {
    type?: "command" | "edit" | "tool" | "network" | "install" | "custom";
    summary?: string;
    command?: string;
    cwd?: string;
    tool?: string;
    diff?: string;
    risk?: string;
  };
  scopes?: FeedApproveScope[];
  // confirm
  statement?: string;
  confirm_label?: string;
  cancel_label?: string;
  destructive?: boolean;
  // sign-in, passkey
  origin?: string;
  url?: string;
  rp_id?: string;
  ceremony?: "get" | "create";
  browser_tab?: string;
  reason?: string;
  // review
  subject?: string;
  ref?: string;
  checklist?: string[];
  // file
  purpose?: string;
  // handoff
  resume_hint?: string;
}

export interface FeedAnswerRecord {
  value?: unknown;
  by?: string;
  device?: string;
  at?: number;
}

export interface FeedCancelRecord {
  reason?: "declined" | "answered_elsewhere" | "expired" | "withdrawn" | string;
  by?: string;
  at?: number;
  note?: string;
}

/** What one Feed row says, built by the owner from the item (FeedRowContent). */
export interface FeedRow {
  headline: string;
  detail?: string;
  detail_is_code: boolean;
  who?: string;
  where?: string;
  /** An icon registry name (`terminal`, `agent.question`, `feed.choice`, ...). */
  icon: string;
  urgent: boolean;
  dimmed: boolean;
  local: boolean;
}

export interface GitHubCheck {
  name: string;
  conclusion?: string | null;
}

export interface GitHubDetail {
  title: string;
  repo: string;
  number?: number;
  url: string;
  body?: string;
  branch?: string;
  checks: GitHubCheck[];
}

export type GitHubAction = "open" | "checkout" | "start_agent" | "approve" | "request_changes" | "comment";

/** An item's wire JSON (FeedDO shape) plus the reader's overlay. */
export interface ViewItem {
  id: string;
  /** `cloud` or `local:<install>`. */
  home: string;
  kind: string;
  title: string;
  body?: string;
  prompt?: FeedPromptWire;
  priority?: FeedPriority;
  dedupe_key?: string;
  thread?: string;
  context?: FeedContext;
  attachments?: FeedAttachment[];
  actions?: FeedPosterAction[];
  expires_at?: number;
  poster: FeedPoster;
  state: FeedItemState;
  answer?: FeedAnswerRecord;
  cancel?: FeedCancelRecord;
  read_at?: number | null;
  seen_at?: number | null;
  archived_at?: number | null;
  snoozed_until?: number | null;
  count?: number;
  revision?: number;
  created_at: number;
  updated_at?: number;
  closed_at?: number | null;
  /** An intent on the item waits for the owner (drawn dimmed). */
  pending: boolean;
  row: FeedRow;
  github?: GitHubDetail;
  github_actions?: GitHubAction[];
}

export type FeedGroupId = "requests" | "rest" | "needs_you" | "today" | "earlier";

export interface FeedEntry {
  id: string;
  item: ViewItem;
  /** Thread members after the head (inbox). */
  members: ViewItem[];
  unread: boolean;
}

export interface FeedGroup {
  id: FeedGroupId;
  entries: FeedEntry[];
}

export type FeedConnectionState = "connecting" | "connected" | "disconnected";

export interface FeedView {
  revision: number;
  loaded: boolean;
  /** The cloud lease's person the view is for; null signed out. */
  account?: { id: string; user: string | null } | null;
  connection: { state: FeedConnectionState; reason?: string };
  counts: { open_requests: number; unread_notices: number; badge: number; unread: number };
  github: { enabled: boolean };
  reports: { available: boolean };
  groups: FeedGroup[];
  total: number;
}

export interface FeedChanged {
  revision: number;
}

export type FeedIntentKind = "answer" | "decline" | "read" | "archive" | "snooze" | "mark_all_read";

export interface FeedIntentParams {
  kind: FeedIntentKind;
  item?: string;
  items?: string[];
  answer?: unknown;
  until?: number;
  before?: number;
  idempotency_key: string;
}

export interface FeedReport {
  id: string;
  sender: string;
  body: string;
  created_at: number;
}

export interface FeedReportsResult {
  reports: FeedReport[];
}

export interface FeedReportReplyParams {
  session: string;
  text: string;
  prompt_id: string;
}

/** Canonical op names; DaemonPageRelay forwards `cmux.feed.<op>` to the daemon as `feed.<op>`. */
export const FeedOps = {
  viewRead: "cmux.feed.view.read",
  viewChanged: "cmux.feed.view.changed",
  intent: "cmux.feed.intent",
  reportsRead: "cmux.feed.reports.read",
  reportsChanged: "cmux.feed.reports.changed",
  reportsReply: "cmux.feed.reports.reply",
  githubRefresh: "cmux.feed.github.refresh",
} as const;

/** The native UI op that runs a registry action in the hosting app (react-pages.md 1.3). */
export const ACTION_RUN = "cmux.app.action.run";

/** The app's actions the page runs (served by Swift, the same handlers the palette uses). */
export const FeedActions = {
  /** Opens the item's context: its terminal, tab, browser tab, sign-in pane or URL. */
  openItem: "feed.openItem",
  /** A GitHub item's action (`{item, action, comment?}`). */
  githubAction: "feed.githubAction",
  /** Settings (Add connection opens Notifications at the GitHub setting). */
  openSettings: "openSettings",
} as const;

/** Add connection's Settings place: the GitHub connection's switch. */
export const ADD_CONNECTION_SETTINGS = { section: "notifications", setting: "feed.github.enabled" } as const;

/** The catalog refusal a feed refusal arrives in (the relay prefixes `cmux.`); its feed code is
 * `details.extra.code`, and `feed.closed`'s item `details.extra.details.item`. */
export const OPERATION_FAILED = "cmux.operation.failed";

/** Refusal codes of `feed.intent` (feed-page.md section 2). */
export const FeedRejectCodes = {
  closed: "feed.closed",
  moving: "feed.moving",
  disconnected: "feed.disconnected",
  rejected: "feed.rejected",
  invalid: "cmux.validation.invalid",
} as const;
