// The Messages list's model, ported from the native Home's `HomeSidebarModel`, `HomePins`,
// `HomeRowText` and MessagesLab's list filter: what the list shows from the conversations the
// Channels data layer keeps (home-channels/store.ts), with no view work. Pure: the list component,
// its tests and the gallery all read it.
//
// - The pinned grid: my pins in my pin order (the owner's `pinPosition`), then every other
//   conversation newest activity first.
// - A search (title, preview or another member's name; case, width and accents aside) or the Unread
//   filter lists the matching conversations as rows, pinned ones first, and no grid.
// - Each row: avatar, name, a two-line preview, Messages' list time and the unread dot.
import { activityAt, channelIds, chiefState, conversationName, type ChiefState } from "../../home-channels/model";
import type { HomeConversation, HomeParticipant } from "../../home-channels/types";

/** One conversation as the list draws it (a row or a pinned tile). */
export interface ListItem {
  id: string;
  conversation: HomeConversation;
  /** The name (the conversation's title, else its members), or "Conversation". */
  title: string;
  /** A group with its own name and Chief (`#name` in Channels); the list tags it "Channel". */
  channel: boolean;
  /** The participant whose avatar the row draws (a DM's or Chief's other side), if one. */
  peer?: HomeParticipant;
  /** The other members in display order (a group's avatar shows up to three). */
  members: readonly HomeParticipant[];
  /** The newest message on one line. */
  preview: string;
  /** "1:46 PM", "Yesterday", "Tuesday", "10/1/26". */
  time: string;
  at: number;
  /** Unread messages or my Mark as Unread (the filter's test). */
  unread: boolean;
  unreadCount: number;
  mentions: number;
  pinned: boolean;
  muted: boolean;
  /** A Chief's live state (working, waiting) when the row is a Chief's. */
  state?: ChiefState;
  /** The tag after the name: a Chief's place or engine, else "Channel" on a channel. */
  badge?: string;
  /** What a screen reader reads: the name, the tag, unread and mention state, the time, the preview. */
  label: string;
}

export interface ListModel {
  pinned: readonly ListItem[];
  rows: readonly ListItem[];
}

/** The words the model puts in rows (the page's string table: `home.*` keys of the Swift list). */
export interface ListWords {
  untitled: string;
  yesterday: string;
  channel: string;
  mentioned: string;
  /** "3 unread" for a count. */
  unread(count: number): string;
}

export interface ListOptions {
  me?: string;
  query?: string;
  unreadOnly?: boolean;
  /** The clock the times read (ms). */
  now: number;
  language: string;
  words: ListWords;
  /** Each conversation's tag after the name (a Chief's "Main", place or engine), by id. */
  badges?: ReadonlyMap<string, string>;
  /** Who types or writes a reply, by conversation: a Chief's row shows it working. */
  activity?: ReadonlyMap<string, ReadonlySet<string>>;
}

/** Folded for comparison as `localizedStandardContains` folds: case, width and accents aside. */
export function fold(text: string): string {
  return text.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase();
}

/** A search match: the title, the preview or another member's name. */
export function matches(item: ListItem, needle: string): boolean {
  const n = fold(needle);
  if (!n) return true;
  return (
    fold(item.title).includes(n) || fold(item.preview).includes(n) || item.members.some((p) => fold(p.name).includes(n))
  );
}

/** Messages' list time: the time today, "Yesterday", the weekday within the last week, else the
 * short date, in the locale's own words and order. No time for a conversation with no activity. */
export function listTime(at: number, now: number, language: string, yesterday: string): string {
  if (!at) return "";
  const then = new Date(at);
  const today = new Date(now);
  const startOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((startOf(today) - startOf(then)) / 86_400_000);
  if (days <= 0) return new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(then);
  if (days === 1) return yesterday;
  if (days <= 6) return new Intl.DateTimeFormat(language, { weekday: "long" }).format(then);
  return new Intl.DateTimeFormat(language, { dateStyle: "short" }).format(then);
}

/** The list order before any search or filter: the pinned rows in my pin order (lower position
 * first; equal positions keep the newest first), then the others newest activity first (ties by id). */
export function splitPinned(conversations: Iterable<HomeConversation>): {
  pinned: HomeConversation[];
  rest: HomeConversation[];
} {
  const all = [...conversations].sort((a, b) => activityAt(b) - activityAt(a) || (a.id < b.id ? -1 : 1));
  const pinned: HomeConversation[] = [];
  const rest: HomeConversation[] = [];
  for (const conversation of all) (conversation.pinned ? pinned : rest).push(conversation);
  pinned.sort((a, b) => (a.pinPosition ?? 0) - (b.pinPosition ?? 0));
  return { pinned, rest };
}

/** The list as it shows (see the file comment). */
export function listModel(conversations: ReadonlyMap<string, HomeConversation>, options: ListOptions): ListModel {
  const { me, now, language, words, badges, activity } = options;
  const channels = channelIds(conversations.values(), me);
  const { pinned, rest } = splitPinned(conversations.values());
  const item = (conversation: HomeConversation): ListItem => {
    const channel = channels.has(conversation.id);
    const members = conversation.participants.filter((p) => p.id !== me);
    const peer = channel || conversation.kind === "group" ? undefined : members[0];
    const name = conversationName(conversation, me).trim();
    const title = name || words.untitled;
    const at = activityAt(conversation);
    const time = listTime(conversation.lastAt ?? 0, now, language, words.yesterday);
    const unreadCount = Math.max(conversation.unread, conversation.markedUnread ? 1 : 0);
    const preview = (conversation.lastText ?? "").replace(/\s*\n+\s*/g, " ").trim();
    const badge = badges?.get(conversation.id) ?? (channel ? words.channel : undefined);
    const state = channel ? undefined : chiefState(conversation, me, activity?.get(conversation.id));
    const label = [
      title,
      ...(badge ? [badge] : []),
      ...(unreadCount > 0 ? [words.unread(unreadCount)] : []),
      ...(conversation.mentions > 0 ? [words.mentioned] : []),
      ...(time ? [time] : []),
      ...(preview ? [preview] : []),
    ].join(", ");
    return {
      id: conversation.id,
      conversation,
      title,
      channel,
      ...(peer ? { peer } : {}),
      members,
      preview,
      time,
      at,
      unread: unreadCount > 0,
      unreadCount,
      mentions: conversation.mentions,
      pinned: conversation.pinned,
      muted: conversation.muted,
      ...(state && state !== "idle" ? { state } : {}),
      ...(badge ? { badge } : {}),
      label,
    };
  };
  const query = options.query?.trim() ?? "";
  const pinnedItems = pinned.map(item);
  const restItems = rest.map(item);
  if (!query && !options.unreadOnly) return { pinned: pinnedItems, rows: restItems };
  // A search or a filter lists every match as a row, pinned ones first, and no grid.
  const rows = [...pinnedItems, ...restItems].filter(
    (row) => (!options.unreadOnly || row.unread) && (!query || matches(row, query)),
  );
  return { pinned: [], rows };
}

/** The list's visual order: the pinned grid, then the rows. */
export function listOrder(model: ListModel): string[] {
  return [...model.pinned, ...model.rows].map((item) => item.id);
}

/** The conversation `offset` places after `current` in the list's visual order. Past either end:
 * undefined (Messages stops there), or with `wrapping` the other end. With nothing selected, or one
 * no longer listed, the first. */
export function neighbor(
  model: ListModel,
  current: string | undefined,
  offset: number,
  wrapping = false,
): string | undefined {
  const order = listOrder(model);
  const index = current === undefined ? -1 : order.indexOf(current);
  if (index < 0) return order[0];
  const next = index + offset;
  if (wrapping) return order[((next % order.length) + order.length) % order.length];
  return order[next];
}

/** The `number`th conversation (1-based), as Select Tab 1…9 picks a tab: 9, or past the end, is the last. */
export function conversationNumber(model: ListModel, number: number): string | undefined {
  const order = listOrder(model);
  if (order.length === 0) return undefined;
  if (number >= 9) return order[order.length - 1];
  return order[Math.min(Math.max(number, 1) - 1, order.length - 1)];
}

/** The grid's order after a drag put `id` at `index` (a tile moved, or a row dropped in). */
export function placePinned(shown: readonly string[], id: string, index: number): string[] {
  const order = shown.filter((other) => other !== id);
  order.splice(Math.min(Math.max(0, index), order.length), 0, id);
  return order;
}

/** The conversations the list draws an unread dot on, pinned first, without muted ones: what Home's
 * unread count outside the list reads. */
export function unreadConversations(model: ListModel): string[] {
  return [...model.pinned, ...model.rows].filter((item) => item.unread && !item.muted).map((item) => item.id);
}

/** The list holds at most one conversation and nothing under it: a narrow column folds it away. */
export function holdsOneConversation(model: ListModel, extras: { note?: string; requests?: number }): boolean {
  return model.pinned.length + model.rows.length <= 1 && !extras.note && !extras.requests;
}
