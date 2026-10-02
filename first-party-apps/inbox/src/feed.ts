/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The feed protocol this view needs (proposed ops; the feed owner does not
// exist yet). The feed is one system for notifications and requests: a
// per-user owner synced to every device, with a local owner as fallback.
// Agents, apps, runs and integrations post items; this app only reads,
// marks, snoozes and responds. It keeps no item model of its own: order,
// grouping, counts, seen, done and snooze state, and wake-ups all belong to
// the owner. These types describe the wire shape only.

export type FeedKind = "notify" | "request" | "watch" | "cancel"
export type RequestKind = "question" | "choice" | "approve" | "confirm" | "sign-in" | "passkey" | "review" | "input" | "file" | "handoff"
export type FeedStatus = "open" | "snoozed" | "done" | "canceled" | "expired"
export type Urgency = "low" | "normal" | "high" | "critical"
export type SourceKind = "agent" | "app" | "run" | "integration" | "user"

export interface FeedSource {
  kind: SourceKind
  /** Stable id of the poster (agent id, app id, run id, integration provider, user id). */
  id: string
  /** Display name ("Claude", "GitHub", "nightly-backup"). */
  name: string
}

/** What the item is about; every field optional. Names are resolved by the owner. */
export interface FeedSubject {
  machine?: string
  workspace?: string
  workspaceName?: string
  tab?: string
  terminal?: string
  browser?: string
  agent?: string
  url?: string
}

/** How a request is answered. `external` means it is completed elsewhere (sign-in, passkey) after `open`. */
export type ResponseSchema =
  | { type: "choice"; options: Array<{ value: string; label: string; destructive?: boolean }> }
  | { type: "approve" }
  | { type: "confirm" }
  | { type: "text"; placeholder?: string }
  | { type: "external" }

/** An action id from the cmux action registry and its arguments (run through `cmux.actions.run`). */
export interface ActionTarget {
  action: string
  args: Record<string, unknown>
}

export interface FeedAction {
  id: string
  title: string
  kind: "open" | "respond" | "done" | "snooze" | "custom"
  /** For `respond`: the value sent with `feed.respond`. */
  value?: unknown
  /** For `custom`: what runs. */
  target?: ActionTarget
  destructive?: boolean
}

export interface FeedItem {
  /** `feed_…` */
  id: string
  kind: FeedKind
  requestKind?: RequestKind
  title: string
  body?: string
  urgency: Urgency
  needsResponse: boolean
  source: FeedSource
  subject: FeedSubject
  /** Items with the same thread key belong together (one agent turn, one pull request). */
  thread?: string
  status: FeedStatus
  snoozedUntil: string | null
  seenAt: string | null
  createdAt: string
  updatedAt: string
  revision: string
  expiresAt: string | null
  response?: ResponseSchema
  actions: FeedAction[]
  /** What "open" does: show the agent's tab, the pull request, the duplicated browser tab. */
  open?: ActionTarget
}

export interface FeedFilter {
  status?: FeedStatus[]
  kinds?: FeedKind[]
  sources?: SourceKind[]
  workspace?: string
  needsResponse?: boolean
  /** Only items the user has not seen. */
  unseen?: boolean
  query?: string
}

export type FeedGroupBy = "source" | "workspace" | "thread"

export interface FeedCounts {
  /** Open items not seen yet (the badge). */
  unseen: number
  open: number
  needsResponse: number
  /** Open items with urgency high or critical. */
  urgent: number
  snoozed: number
}

export interface FeedGroup {
  key: string
  /** Owner-provided display name (workspace name, provider name). */
  label: string
  /** Set when grouping by source, so the view can localize the label. */
  sourceKind?: SourceKind
  itemIds: string[]
}

export interface FeedListParams {
  filter: FeedFilter
  groupBy?: FeedGroupBy
  cursor?: string
  limit?: number
}

/** Items in the owner's order (most urgent first, then newest). */
export interface FeedListResult {
  items: FeedItem[]
  groups?: FeedGroup[]
  cursor?: string | null
  revision: string
  counts: FeedCounts
}

/** Payload of the `feed.changed` event. */
export interface FeedChanged {
  revision: string
  changed: string[]
  counts: FeedCounts
}

export interface FeedMutation {
  revision: string
  /** How many items changed state. */
  changed?: number
}

export const FEED_CHANGED = "feed.changed"

/** Thin wrappers over the proposed ops. */
export const feed = {
  list: (params: FeedListParams) => cmux.call<FeedListResult>("feed.list", params),
  get: (item: string) => cmux.call<FeedItem>("feed.get", { item }),
  counts: () => cmux.call<FeedCounts>("feed.counts", {}),
  mark: (items: string[], state: "seen" | "done" | "open") => cmux.call<FeedMutation>("feed.mark", { items, state }),
  /** Marks every item matching `filter` ("mark all as seen" without listing everything first). */
  markMatching: (filter: FeedFilter, state: "seen" | "done") => cmux.call<FeedMutation>("feed.mark", { filter, state }),
  snooze: (item: string, until: string) => cmux.call<FeedMutation>("feed.snooze", { item, until }),
  /** Origin `user` only: call it synchronously from a tap or menu handler. */
  respond: (item: string, value: unknown) => cmux.call<FeedMutation>("feed.respond", { item, value })
}

export const isUnseen = (i: FeedItem) => i.seenAt === null
