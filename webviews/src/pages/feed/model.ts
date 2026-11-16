// The Feed page's pure presentation (plans/cmux-next/feed-page.md section 3): the route, the Inbox
// filter, selection, drafts, choice validation for Send, answer values, the row's meta line and
// relative times. The owner (the daemon's feed client) filters, orders and groups; nothing here
// sorts the feed or keeps a copy of it. Ported from the Swift views it replaces (FeedDrafts,
// FeedChoiceValidation, FeedRelativeTime, ReportReply, FeedRowContent's meta, FeedStrings.closed).
import type { Strings } from "../shared/i18n";
import type {
  FeedApproveScope,
  FeedAttachment,
  FeedCategory,
  FeedChoiceQuestion,
  FeedConnectionFilter,
  FeedEntry,
  FeedGroup,
  FeedReport,
  FeedView,
  ViewItem,
} from "./types";

// MARK: - Route

export type FeedRouteView = "inbox" | "list" | "needs-you";
/** Where the page is shown, which decides the ground it paints: a page tab or the right sidebar. */
export type FeedSurface = "page" | "sidebar";
/** How Home's pinned Needs you section draws (FeedTunables.needsYouStyle). */
export type NeedsYouStyle = "rows" | "cards" | "bar";
/** The Inbox's detail layout (gallery variants; `split` is the default). */
export type InboxDensity = "split" | "compact" | "stacked";

export interface FeedRoute {
  view: FeedRouteView;
  surface: FeedSurface;
  style: NeedsYouStyle;
  /** The most requests Needs you lists; the rest are counted. */
  limit: number;
  density: InboxDensity;
}

export const NEEDS_YOU_LIMIT = 3;

const DEFAULT_SURFACE: Record<FeedRouteView, FeedSurface> = { inbox: "page", list: "sidebar", "needs-you": "page" };

function oneOf<T extends string>(value: string | null | undefined, allowed: readonly T[], fallback: T): T {
  return value && (allowed as readonly string[]).includes(value) ? (value as T) : fallback;
}

/**
 * `#/inbox`, `#/list?surface=sidebar`, `#/needs-you?style=cards&limit=3`. The surface and the
 * Needs you style may also come as document attributes (`data-feed-surface`, `data-feed-style`),
 * which the host sets before the page runs; the route query wins.
 */
export function parseRoute(hash: string, attributes: { surface?: string; style?: string } = {}): FeedRoute {
  const raw = hash.replace(/^#/, "");
  const [path = "", query = ""] = raw.split("?", 2);
  const params = new URLSearchParams(query);
  const view = oneOf(path.replace(/^\//, ""), ["inbox", "list", "needs-you"] as const, "inbox");
  const limit = Number(params.get("limit"));
  return {
    view,
    surface: oneOf(params.get("surface") ?? attributes.surface, ["page", "sidebar"] as const, DEFAULT_SURFACE[view]),
    style: oneOf(params.get("style") ?? attributes.style, ["rows", "cards", "bar"] as const, "rows"),
    limit: Number.isInteger(limit) && limit > 0 ? limit : NEEDS_YOU_LIMIT,
    density: oneOf(params.get("density"), ["split", "compact", "stacked"] as const, "split"),
  };
}

/**
 * The item the app asks the Inbox to show (`#/inbox?surface=page&item=<id>`): Needs you's request
 * whose own tab is gone opens the Inbox on it. It is a one-time request, not part of the route.
 */
export function routeItem(hash: string): string | undefined {
  const [path = "", query = ""] = hash.replace(/^#/, "").split("?", 2);
  if (path.replace(/^\//, "") !== "inbox") return undefined;
  return new URLSearchParams(query).get("item") || undefined;
}

/** `hash` without its `item` request, so the same request sent again changes the fragment. */
export function withoutRouteItem(hash: string): string {
  const [path = "", query] = hash.replace(/^#/, "").split("?", 2);
  if (query === undefined) return `#${path}`;
  const params = new URLSearchParams(query);
  params.delete("item");
  const rest = params.toString();
  return rest ? `#${path}?${rest}` : `#${path}`;
}

// MARK: - Inbox filter (client view state)

/** `reports` shows the reports basket in place of the item list, so it filters no items. */
export type InboxConnection = FeedConnectionFilter | "reports";

export interface InboxFilter {
  connection: InboxConnection;
  category: FeedCategory;
  query: string;
}

export const DEFAULT_FILTER: InboxFilter = { connection: "feed", category: "all", query: "" };
export const CATEGORIES: readonly FeedCategory[] = ["all", "unread", "needs_you", "notices"];
export const CATEGORY_LABEL: Record<FeedCategory, string> = {
  all: "feed.allItems",
  unread: "feed.unread",
  needs_you: "group.needsYou",
  notices: "feed.notices",
};

// MARK: - Items

export const isRequest = (item: ViewItem) => item.kind !== "notice";
export const isOpenRequest = (item: ViewItem) => isRequest(item) && item.state === "open";
export const isUnread = (item: ViewItem) => item.read_at == null;
export const isArchived = (item: ViewItem) => item.archived_at != null;
export const isLocal = (item: ViewItem) => item.home.startsWith("local:");
const HIGH = new Set(["high", "urgent"]);
/** The kind's default priority (feed.md 3.4): notices, reviews and custom kinds are normal. */
const defaultPriority = (kind: string) =>
  kind === "notice" || kind === "review" || kind.startsWith("x-") ? "normal" : "high";
export const isUrgent = (item: ViewItem) =>
  isOpenRequest(item) && HIGH.has(item.priority ?? defaultPriority(item.kind));

/** A GitHub item (FeedInboxFilter.isGitHub): its actions card shows in the detail. */
export function isGitHub(item: ViewItem): boolean {
  return item.dedupe_key?.startsWith("github:") === true || item.poster.label === "GitHub";
}

/** "Claude Code · api-server" (FeedPoster.displayLabel). */
export function posterLabel(item: ViewItem): string {
  const { harness, label } = item.poster;
  if (!harness) return label;
  return label ? `${harness} · ${label}` : harness;
}

/** The edit's diff: the one the approve action names, else the first diff attachment. */
export function diffAttachment(item: ViewItem): FeedAttachment | undefined {
  const attachments = item.attachments ?? [];
  const named = item.prompt?.action?.diff;
  const isDiff = (a: FeedAttachment) =>
    a.mime === "text/x-diff" || a.mime === "text/x-patch" || a.name.endsWith(".diff") || a.name.endsWith(".patch");
  return (named ? attachments.find((a) => a.id === named) : undefined) ?? attachments.find(isDiff);
}

/** The closed state of a request, for its row and the late-answer notice (FeedStrings.closed). */
export function closedStatus(item: ViewItem, strings: Pick<Strings, "t" | "format">): string | undefined {
  switch (item.state) {
    case "open":
      return undefined;
    case "answered": {
      const device = item.answer?.device;
      return device ? strings.format("item.answeredOn", device) : strings.t("item.answered");
    }
    case "expired":
      return strings.t("item.expired");
    case "cancelled":
      if (item.cancel?.reason === "declined") return strings.t("item.declined");
      if (item.cancel?.reason === "answered_elsewhere") return strings.t("item.answeredInTerminal");
      return strings.t("item.cancelled");
  }
}

/** "Claude Code · api-server › Fix login · Expired · ×2 · 3 items" (FeedRowCell's meta line). */
export function metaLine(item: ViewItem, threadCount: number, strings: Pick<Strings, "t" | "format">): string {
  const parts = [item.row.who, item.row.where, closedStatus(item, strings)].filter(
    (part): part is string => !!part && part.trim() !== "",
  );
  if ((item.count ?? 1) > 1) parts.push(`×${item.count}`);
  if (threadCount > 1) parts.push(strings.format("item.threadCount", String(threadCount)));
  return parts.join(" · ");
}

// MARK: - Times (they advance only on events and actions: nothing ticks while the page is idle)

const UNITS: ReadonlyArray<[limit: number, unit: Intl.NumberFormatOptions["unit"], seconds: number]> = [
  [60, "second", 1],
  [3_600, "minute", 60],
  [86_400, "hour", 3_600],
  [Infinity, "day", 86_400],
];
const relativeFormats = new Map<string, Intl.NumberFormat>();

/** "40s", "3m", "2h", "1d": one unit, rounded down, localized (FeedRelativeTime). */
export function relativeTime(at: number, now: number, language: string): string {
  const seconds = Math.max(0, (now - at) / 1000);
  const [, unit, size] = UNITS.find(([limit]) => seconds < limit)!;
  const key = `${language}:${unit}`;
  let format = relativeFormats.get(key);
  if (!format) {
    format = new Intl.NumberFormat(language, { style: "unit", unit, unitDisplay: "narrow" });
    relativeFormats.set(key, format);
  }
  return format.format(Math.floor(seconds / size));
}

/** "Oct 26, 2026 at 9:12 AM": a row time's tooltip. */
export function fullDate(at: number, language: string): string {
  return new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(at);
}

export function shortTime(at: number, language: string): string {
  return new Intl.DateTimeFormat(language, { timeStyle: "short" }).format(at);
}

export function longDateTime(at: number, language: string): string {
  return new Intl.DateTimeFormat(language, { dateStyle: "long", timeStyle: "short" }).format(at);
}

// MARK: - Lines (what a list draws, top to bottom)

/** One Feed row is 66 px with a detail line, 48 without; a group title 30 (FeedRowsView). */
export const ROW_HEIGHT = 66;
export const SHORT_ROW_HEIGHT = 48;
export const HEADER_HEIGHT = 30;
/** Past this many lines a list draws only the rows near the viewport. */
export const VIRTUALIZE_AFTER = 200;

export type FeedLine =
  | { type: "header"; id: string; title: string; count: number }
  | { type: "row"; id: string; entry: FeedEntry; threadCount: number; pending: boolean; selected: boolean };

export function lineHeight(line: FeedLine): number {
  if (line.type === "header") return HEADER_HEIGHT;
  return line.entry.item.row.detail ? ROW_HEIGHT : SHORT_ROW_HEIGHT;
}

const GROUP_TITLE: Partial<Record<FeedGroup["id"], string>> = {
  needs_you: "group.needsYou",
  today: "group.today",
  earlier: "group.earlier",
};

/** The Inbox column: each group's title and count, then one row per item or collapsed thread. */
export function inboxLines(
  groups: readonly FeedGroup[],
  shown: string | undefined,
  pending: (item: ViewItem) => boolean,
  t: (key: string) => string,
): FeedLine[] {
  const lines: FeedLine[] = [];
  for (const group of groups) {
    const title = GROUP_TITLE[group.id];
    if (!title || group.entries.length === 0) continue;
    lines.push({ type: "header", id: `header:${group.id}`, title: t(title), count: group.entries.length });
    for (const entry of group.entries) {
      const all = [entry.item, ...entry.members];
      lines.push({
        type: "row",
        id: entry.id,
        entry,
        threadCount: all.length,
        pending: all.some(pending),
        selected: shown !== undefined && all.some((item) => item.id === shown),
      });
    }
  }
  return lines;
}

/** The list variant's rows after its request cards (the `rest` group). */
export function restLines(
  groups: readonly FeedGroup[],
  selection: string | undefined,
  pending: (item: ViewItem) => boolean,
): FeedLine[] {
  const rest = groups.find((group) => group.id === "rest")?.entries ?? [];
  return rest.map((entry) => ({
    type: "row",
    id: entry.id,
    entry,
    threadCount: 1,
    pending: pending(entry.item),
    selected: entry.item.id === selection,
  }));
}

/** The view is hydrated, so an empty one means nothing waits: the cloud owner's snapshot came for this
 * account (`loaded`; the daemon keeps it through a later reconnect), or there is no cloud part (signed
 * out). Before that (connecting, or after a first connection that failed) an empty view is still
 * loading, never "Nothing new". */
export function isHydrated(view: FeedView | undefined): view is FeedView {
  if (!view) return false;
  return view.loaded || (view.connection.state === "disconnected" && view.connection.reason === "signed_out");
}

export function groupEntries(view: FeedView | undefined, id: FeedGroup["id"]): FeedEntry[] {
  return view?.groups.find((group) => group.id === id)?.entries ?? [];
}

export function allItems(groups: readonly FeedGroup[]): ViewItem[] {
  return groups.flatMap((group) => group.entries.flatMap((entry) => [entry.item, ...entry.members]));
}

/** The selected item when the filtered groups still hold it (FeedInboxFilter.selectedItem). */
export function shownItem(groups: readonly FeedGroup[], selection: string | undefined): ViewItem | undefined {
  if (!selection) return undefined;
  return allItems(groups).find((item) => item.id === selection);
}

/** The entry (item or collapsed thread) an item belongs to. */
export function entryOf(groups: readonly FeedGroup[], id: string): FeedEntry | undefined {
  for (const group of groups)
    for (const entry of group.entries) if (entry.item.id === id || entry.members.some((m) => m.id === id)) return entry;
  return undefined;
}

/** Up/Down over a list's rows: the next row's item, past the ends it stays. */
export function moveSelection(
  lines: readonly FeedLine[],
  current: string | undefined,
  delta: 1 | -1,
): string | undefined {
  const rows = lines.filter((line): line is Extract<FeedLine, { type: "row" }> => line.type === "row");
  if (rows.length === 0) return current;
  const index = rows.findIndex((line) => line.selected || line.entry.item.id === current);
  const next = index < 0 ? (delta > 0 ? 0 : rows.length - 1) : Math.min(rows.length - 1, Math.max(0, index + delta));
  return rows[next]!.entry.item.id;
}

// MARK: - Drafts (unsent answers, per item; client view state shared by every layout)

export interface ChoiceSelection {
  selected: string[];
  other?: string;
}

export interface Drafts {
  choices: Record<string, Record<string, ChoiceSelection>>;
  replies: Record<string, string>;
  scopes: Record<string, FeedApproveScope>;
}

export const EMPTY_DRAFTS: Drafts = { choices: {}, replies: {}, scopes: {} };

export function draftChoice(drafts: Drafts, item: string, question: string): ChoiceSelection {
  return drafts.choices[item]?.[question] ?? { selected: [] };
}

function withChoice(drafts: Drafts, item: string, question: string, selection: ChoiceSelection): Drafts {
  return { ...drafts, choices: { ...drafts.choices, [item]: { ...drafts.choices[item], [question]: selection } } };
}

/** Toggles an option; a single-select question keeps one option and drops "Other". */
export function toggleChoice(drafts: Drafts, item: string, question: FeedChoiceQuestion, option: string): Drafts {
  const current = draftChoice(drafts, item, question.id);
  let next: ChoiceSelection;
  if (current.selected.includes(option))
    next = { ...current, selected: current.selected.filter((id) => id !== option) };
  else if (question.multi) next = { ...current, selected: [...current.selected, option] };
  else next = { selected: [option] };
  return withChoice(drafts, item, question.id, next);
}

/** Typing "Other" on a single-select question clears its picked option. */
export function setOther(drafts: Drafts, item: string, question: FeedChoiceQuestion, text: string): Drafts {
  const current = draftChoice(drafts, item, question.id);
  const next: ChoiceSelection = { selected: !question.multi && text ? [] : current.selected, other: text };
  return withChoice(drafts, item, question.id, next);
}

export function setReply(drafts: Drafts, item: string, text: string): Drafts {
  return { ...drafts, replies: { ...drafts.replies, [item]: text } };
}

export function setScope(drafts: Drafts, item: string, scope: FeedApproveScope): Drafts {
  return { ...drafts, scopes: { ...drafts.scopes, [item]: scope } };
}

export function clearDrafts(drafts: Drafts, item: string): Drafts {
  if (!(item in drafts.choices) && !(item in drafts.replies) && !(item in drafts.scopes)) return drafts;
  const { [item]: _choice, ...choices } = drafts.choices;
  const { [item]: _reply, ...replies } = drafts.replies;
  const { [item]: _scope, ...scopes } = drafts.scopes;
  return { choices, replies, scopes };
}

// MARK: - Choice validation (the owner checks again against the kind's schema)

export type ChoiceIssue =
  | { kind: "unanswered"; question: string }
  | { kind: "tooMany"; question: string }
  | { kind: "unknownOption"; question: string; option: string }
  | { kind: "unknownQuestion"; question: string }
  | { kind: "otherNotAllowed"; question: string };

export function choiceIssues(
  answers: Record<string, ChoiceSelection>,
  questions: readonly FeedChoiceQuestion[],
): ChoiceIssue[] {
  const issues: ChoiceIssue[] = [];
  const known = new Set(questions.map((q) => q.id));
  for (const id of Object.keys(answers).sort())
    if (!known.has(id)) issues.push({ kind: "unknownQuestion", question: id });
  for (const question of questions) {
    const selection = answers[question.id] ?? { selected: [] };
    const other = selection.other?.trim() ?? "";
    const options = new Set(question.options.map((o) => o.id));
    for (const option of selection.selected)
      if (!options.has(option)) issues.push({ kind: "unknownOption", question: question.id, option });
    if (other && !question.allow_other) issues.push({ kind: "otherNotAllowed", question: question.id });
    const count = new Set(selection.selected).size + (other ? 1 : 0);
    if (count === 0) issues.push({ kind: "unanswered", question: question.id });
    else if (count > 1 && !question.multi) issues.push({ kind: "tooMany", question: question.id });
  }
  return issues;
}

/** The answer with blank "Other" text removed, or undefined while it has issues. */
export function normalizedChoice(
  answers: Record<string, ChoiceSelection>,
  questions: readonly FeedChoiceQuestion[],
): Record<string, ChoiceSelection> | undefined {
  if (choiceIssues(answers, questions).length) return undefined;
  const out: Record<string, ChoiceSelection> = {};
  for (const question of questions) {
    const selection = answers[question.id] ?? { selected: [] };
    const other = selection.other?.trim() ?? "";
    out[question.id] = other ? { selected: selection.selected, other } : { selected: selection.selected };
  }
  return out;
}

/** One single-select question: a tap on an option answers. */
export function isOneTap(questions: readonly FeedChoiceQuestion[]): boolean {
  return questions.length === 1 && questions.every((q) => !q.multi && !q.allow_other);
}

// MARK: - Answer values (feed.md 3.4 "Answer value"; FeedWireEncode.answer)

export const Answers = {
  text: (text: string) => ({ text }),
  choice: (answers: Record<string, ChoiceSelection>) => ({ answers }),
  approve: (decision: "allow" | "deny", scope?: FeedApproveScope) =>
    decision === "allow" && scope ? { decision, scope } : { decision },
  confirm: (confirmed: boolean) => ({ confirmed }),
  review: (verdict: "approve" | "request_changes", comment?: string) => (comment ? { verdict, comment } : { verdict }),
  handoff: (status: "taken_over") => ({ status }),
};

/** A Needs you row answers in place only with one click; a question or a choice opens instead. */
export function answersInline(item: ViewItem): boolean {
  return item.kind !== "notice" && item.kind !== "question" && item.kind !== "choice";
}

export function approveScopes(item: ViewItem): FeedApproveScope[] {
  const scopes = item.prompt?.scopes ?? [];
  return scopes.length ? scopes : ["once"];
}

export const SCOPE_LABEL: Record<FeedApproveScope, string> = {
  once: "scope.once",
  session: "scope.session",
  always: "scope.always",
};

// MARK: - Needs you

export function splitNeedsYou<T>(requests: readonly T[], limit: number): { shown: T[]; more: number } {
  const keep = Math.max(1, limit);
  return { shown: requests.slice(0, keep), more: Math.max(0, requests.length - keep) };
}

// MARK: - Snooze

export type SnoozeFor = "hour" | "tomorrow";

export function snoozeUntil(now: number, length: SnoozeFor): number {
  return now + (length === "hour" ? 3_600_000 : 86_400_000);
}

// MARK: - Reports

export interface ReportReply {
  session: string;
  text: string;
  promptId: string;
}

/** A reply sent again (same session and text) keeps the id of the one that was not sent, so a
 * send that passed its deadline after acpmux queued it is delivered once (ReportReply). */
export function reportReply(
  session: string,
  text: string,
  previous: ReportReply | undefined,
  mint: () => string,
): ReportReply {
  const promptId = previous && previous.session === session && previous.text === text ? previous.promptId : mint();
  return { session, text, promptId };
}

export function reconcileReportSelection(reports: readonly FeedReport[], selection: string | undefined) {
  if (selection && reports.some((report) => report.id === selection)) return selection;
  return reports[0]?.id;
}

// MARK: - Icons

/** A row's tint (FeedGlyph): attention for an urgent request, the text for an open one. */
export function glyphTone(item: ViewItem): "attention" | "primary" | "secondary" | "tertiary" {
  if (isOpenRequest(item)) return item.row.urgent ? "attention" : "primary";
  if (item.row.dimmed || item.state === "expired" || item.state === "cancelled") return "tertiary";
  return "secondary";
}
