/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The feed's wire shapes (backend/packages/protocol/src/feed.ts, plans/cmux-next/feed.md).
// The feed owner (FeedDO, with a local fallback owner) keeps items, lifecycle,
// answers, triage, order, groups and counts. This app is a view: it lists,
// derives changes from the owner's op events, and sends the user's actions.

export type PosterKind = "agent" | "harness" | "app" | "server" | "vm" | "automation" | "integration" | "system" | "user"
export type Priority = "low" | "normal" | "high" | "urgent"
export type ItemState = "open" | "answered" | "cancelled" | "expired"
export type CancelReason = "poster" | "declined" | "answered_elsewhere" | "superseded" | "poster_gone"
export type OpenAction = "tab.focus" | "workspace.focus" | "browser.open" | "browser.duplicateRight" | "url.open" | "task.open" | "acp.session.open" | "app.open"

export interface FeedContext {
  host?: string
  workspace?: string
  tab?: string
  terminal?: string
  browser_tab?: string
  acp_session?: string
  task?: string
  url?: string
}

/** A poster button: with `answer` it answers the request with that value; without, it only opens the context. */
export interface FeedAction {
  id: string
  label: string
  style?: "default" | "primary" | "destructive"
  answer?: unknown
}

export interface FeedPoster {
  kind: PosterKind
  scope: string
  label: string
  install?: string
  agent?: string
  harness?: string
}

export interface FeedItem {
  /** `fi_` + 20 characters. */
  id: string
  home: string
  type: "notice" | "request"
  /** `notice`, a built-in request kind, or `x-<publisher>.<name>`. */
  kind: string
  title: string
  body: string
  prompt?: unknown
  answer_schema?: unknown
  priority: Priority
  dedupe_key: string | null
  thread: string | null
  context: FeedContext
  attachments: Array<{ id: string; name: string; mime: string; size: number }>
  actions: FeedAction[]
  open: { action: OpenAction; args: Record<string, unknown> } | null
  poster: FeedPoster
  state: ItemState
  answer: { value: unknown; by: string; device: string | null; at: number } | null
  cancel: { reason: CancelReason; by: string; at: number; note: string | null } | null
  needs_mac: boolean
  expires_at: number
  read_at: number | null
  seen_at: number | null
  archived_at: number | null
  snoozed_until: number | null
  count: number
  order: number
  revision: number
  created_at: number
  updated_at: number
  closed_at: number | null
}

/** Selector for bulk triage (`feed.read`, `feed.archive`) and list filters. */
export interface FeedFilter {
  poster_kind?: PosterKind
  thread?: string
  workspace?: string
  kind?: string
}

export type GroupBy = "thread" | "poster" | "workspace"

export interface ListParams extends FeedFilter {
  state?: "open" | "closed" | "all"
  type?: "notice" | "request"
  unread?: boolean
  archived?: boolean
  needs_response?: boolean
  query?: string
  order?: "urgent" | "recent"
  group_by?: GroupBy
  after?: string
  limit?: number
}

export interface FeedGroup {
  key: string
  label: string
  items: string[]
}

export interface ListResult {
  items: FeedItem[]
  groups?: FeedGroup[]
  next: string | null
  revision: string
}

export interface Counts {
  open_requests: number
  unread: number
  by_priority: Record<string, number>
  by_poster_kind: Record<string, number>
}

/** One committed op on the user's feed stream (the owner's mirror-replay form). */
export interface FeedEvent {
  stream: string
  seq: number
  tx: string
  op: string
  params: unknown
  actor: { identity: string; kind?: string }
  origin: string
  at: number
}

/** The user's feed stream as the app host exposes it (the host binds it to `feed:<user>`). */
export const FEED_STREAM = "feed"

export const isOpenRequest = (i: Pick<FeedItem, "type" | "state">) => i.type === "request" && i.state === "open"
export const isUnread = (i: Pick<FeedItem, "read_at">) => i.read_at === null

type Selection = { items: string[] } | { all: true } | { filter: FeedFilter }

/** Thin wrappers over the feed ops. Answers and declines carry the gesture of the user's tap. */
export const feed = {
  list: (params: ListParams) => cmux.call<ListResult>("feed.list", params),
  get: (item: string) => cmux.call<{ item: FeedItem }>("feed.get", { item }).then((r) => r.item),
  counts: () => cmux.call<Counts>("feed.counts", {}),
  read: (selection: Selection) => cmux.call("feed.read", selection),
  archive: (selection: { items: string[] } | { filter: FeedFilter }) => cmux.call("feed.archive", selection),
  unarchive: (items: string[]) => cmux.call("feed.unarchive", { items }),
  snooze: (items: string[], until: number) => cmux.call("feed.snooze", { items, until }),
  answer: (item: string, answer: unknown, gesture: string) => cmux.call("feed.answer", { item, answer }, { gesture }),
  decline: (item: string, gesture: string) => cmux.call("feed.cancel", { item, reason: "declined" }, { gesture })
}
