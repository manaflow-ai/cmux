// l10n-allow-file: public sample names for DEBUG captures (debug.home.sidebar_fixture), not shipped copy.
// What the app's DEBUG socket verbs ask of the Messages page (host → page, `home.messages.debug`),
// now that the list and the transcript are the page's: the native Home answered them from its own
// views (DebugHomeSidebarFixture, DebugHome+Dock driveDockList, DebugHomeNativeFixture.drive). Only
// a DEBUG app calls it (CmuxNextHome `HomeMessagesDebug`); a page that is never asked does nothing.
//
//   home.messages.debug {action, …}
//     fixture  {count?, pinned?, chiefs?, channels?, team?, width?, select?, search?, unread?,
//               new_message?, intro?}                    -> {rows, …}
//         Fixture conversations on the list only (never the store or the owner), the first `pinned`
//         pinned; `chiefs` [{id, name}] one Chief DM each, `channels` [title] one channel each;
//         `team` fixture teammates New Message offers; `width`, `select` (a row index), `search`
//         (the field focused or not), `unread` (the Unread filter) set the list's look;
//         `new_message` (a team size) opens New Message with the fixture Chiefs and teammates;
//         `intro` ("welcome" | "askFocus") shows that intro on the shown Chief's first run.
//     snapshot {}  -> {list: [{id, title, pinned, unread, chief}], note, cloud, shown, open_thread,
//                     transcript_tail}                     (debug.home `dock` and `page.tabs`)
//     list     {op: pin | unpin | unread | read | menu, conversation, item?}  -> {ok, items?, performed?}
//     drive    {drive: focus | type | send | texts | typing | thread | thread_state | escape | reply,
//               text?, limit?, mine?}                       -> {ok, …}            (debug.home.drive)
import { useEffect, useLayoutEffect, useRef } from "react";
import { messageText, threadOf } from "../home-channels/model";
import type { HomeChannelsStore } from "../home-channels/store";
import type { HomeConversation, HomeParticipant } from "../home-channels/types";
import type { Strings } from "../shared/i18n";
import type { PageClient } from "../shared/pageClient";
import { rowMenu } from "./list/ConversationList";
import type { ListItem, ListModel } from "./list/model";
import type { MessagesNav } from "./nav";
import type { HomeContact } from "./sheets/recipients";
import type { MessagesHost } from "./types";

export const DEBUG_OP = "home.messages.debug";

/** The fixture people's names, in list order (the native fixture's `HomeSidebarFixtureRows.names`). */
export const FIXTURE_NAMES = [
  "Austin",
  "Lucas Wang",
  "Aziz Ali",
  "Mia Chen",
  "Noah Park",
  "Iris Lee",
  "Omar Diaz",
  "Zoe Kim",
  "Sam Fox",
  "Ana Ruiz",
  "Leo Moss",
  "Ivy Hart",
] as const;

/** The fixture Chiefs New Message lists (two alike, as the native fixture's). */
const FIXTURE_CHIEFS: readonly HomeContact[] = [
  { id: "agent_fixture_main", name: "Chief", source: "agent" },
  { id: "agent_fixture_codex", name: "Chief Codex", source: "agent" },
  { id: "agent_fixture_mac_1", name: "Chief", source: "agent" },
  { id: "agent_fixture_mac_2", name: "Chief", source: "agent" },
];

/** What the fixture lays over the page: list-only rows, New Message's people, the list's look. */
export interface DebugOverlay {
  rows: ReadonlyMap<string, HomeConversation>;
  /** New Message's people (none: the host's). */
  contacts?: readonly HomeContact[];
  width?: number;
  /** A fixture row the list marks selected (fixture rows never open). */
  selected?: string;
  intro?: "welcome" | "askFocus";
}

const EMPTY: DebugOverlay = { rows: new Map() };

/** The page's overlay (one per document): the list and the detail read it. */
export class MessagesDebug {
  private state: DebugOverlay = EMPTY;
  private readonly listeners = new Set<() => void>();

  getSnapshot = (): DebugOverlay => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  set(patch: Partial<DebugOverlay>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
}

export const pageDebug = new MessagesDebug();

/** `conversations` with the fixture's rows after them (a fixture row never replaces a real one). */
export function withFixture(
  conversations: ReadonlyMap<string, HomeConversation>,
  overlay: DebugOverlay,
): ReadonlyMap<string, HomeConversation> {
  if (overlay.rows.size === 0) return conversations;
  const merged = new Map(conversations);
  for (const [id, row] of overlay.rows) if (!merged.has(id)) merged.set(id, row);
  return merged;
}

type Json = Record<string, unknown>;
const record = (value: unknown): Json => (value && typeof value === "object" ? (value as Json) : {});
const int = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : undefined;
const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value));

const ME: HomeParticipant = { id: "user_debug_me", kind: "human", name: "Me", chief: false };

function row(
  id: string,
  title: string,
  participants: HomeParticipant[],
  at: number,
  extra: Partial<HomeConversation> = {},
): HomeConversation {
  return {
    id,
    owner: "local",
    title,
    kind: "direct",
    participants,
    lastSeq: 0,
    rev: 1,
    updatedAt: at,
    createdAt: at,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    lastAt: at,
    ...extra,
  };
}

/** The fixture's rows, as the native `HomeSidebarFixtureRows` made them: one DM per name an hour
 * apart (the first `pinned` pinned), one per Chief a minute apart, one channel per title (its own
 * Chief and two teammates, two minutes apart; the first unread). */
export function fixtureRows(
  params: {
    count: number;
    pinned: number;
    chiefs: readonly { id: string; name: string }[];
    channels: readonly string[];
  },
  me: HomeParticipant | undefined,
  now: number,
): Map<string, HomeConversation> {
  const self = me ?? ME;
  const rows = new Map<string, HomeConversation>();
  FIXTURE_NAMES.slice(0, params.count).forEach((name, i) => {
    const id = `conv_fixture_${i}`;
    const other: HomeParticipant = { id: `user_fixture_${i}`, kind: "human", name, chief: false };
    const pinned = i < params.pinned;
    rows.set(
      id,
      row(id, "", [self, other], now - 3_600_000 * (i + 1), pinned ? { pinned: true, pinPosition: i + 1 } : {}),
    );
  });
  params.chiefs.forEach((chief, i) => {
    const id = `conv_fixture_chief_${i}`;
    const agent: HomeParticipant = { id: chief.id, kind: "agent", name: chief.name, chief: true };
    rows.set(id, row(id, chief.name, [self, agent], now - 60_000 * (i + 1), { kind: "chief" }));
  });
  params.channels.forEach((title, i) => {
    const id = `conv_fixture_channel_${i}`;
    const chief: HomeParticipant = {
      id: `agent_fixture_channel_${i}`,
      kind: "agent",
      name: `${title} Chief`,
      chief: true,
    };
    const people = FIXTURE_NAMES.slice(0, 2).map((name, j): HomeParticipant => ({
      id: `user_fixture_channel_${i}_${j}`,
      kind: "human",
      name,
      chief: false,
    }));
    rows.set(
      id,
      row(id, title, [self, chief, ...people], now - 120_000 * (i + 1), {
        kind: "group",
        ...(i === 0 ? { lastSeq: 3, unread: 3 } : {}),
      }),
    );
  });
  return rows;
}

/** New Message's fixture people: the four Chiefs, then `team` teammates. */
export function fixtureContacts(team: number): HomeContact[] {
  const members = FIXTURE_NAMES.slice(0, clamp(team, 0, FIXTURE_NAMES.length)).map((name, i): HomeContact => ({
    id: `user_fixture_team_${i}`,
    name,
    source: "team",
  }));
  return [...FIXTURE_CHIEFS, ...members];
}

/** What the page does to its document (a test gives a fake). */
export interface DebugDom {
  /** Inserts `text` as typed input in the focused element; false when nothing takes it. */
  insertText(text: string): boolean;
  /** Clicks the first match: whether one was there and enabled. */
  click(selector: string): "clicked" | "missing" | "disabled";
  /** The list's search field takes (true) or gives up (false) the keyboard. */
  focusSearch(on: boolean): boolean;
}

export const documentDom: DebugDom = {
  insertText(text) {
    const active = document.activeElement;
    if (!active || active === document.body) return false;
    // The editor's own input path, as a typed character takes it (contenteditable and fields alike).
    return document.execCommand("insertText", false, text);
  },
  click(selector) {
    const element = document.querySelector<HTMLButtonElement>(selector);
    if (!element) return "missing";
    if (element.disabled) return "disabled";
    element.click();
    return "clicked";
  },
  focusSearch(on) {
    const field = document.querySelector<HTMLInputElement>(".hm-search input, input.hm-search-hidden");
    if (!field) return false;
    if (on) field.focus();
    else field.blur();
    return true;
  },
};

/** What the debug commands read and change, at call time. */
export interface DebugContext {
  store: Pick<
    HomeChannelsStore,
    "getSnapshot" | "setPinned" | "setMarkedUnread" | "markConversationRead" | "openThread"
  >;
  nav: Pick<MessagesNav, "focus" | "dismiss" | "openCompose" | "requestFocus" | "getSnapshot">;
  /** The list as it shows now. */
  model: ListModel;
  /** The quiet line under the list (the app's Cloud note), if any. */
  note?: string;
  messages: Pick<MessagesHost, "menu" | "perform">;
  strings: Strings;
  debug: MessagesDebug;
  setUnreadOnly(on: boolean): void;
  dom: DebugDom;
  now(): number;
}

const items = (model: ListModel): ListItem[] => [...model.pinned, ...model.rows];

/** `fixture`: see the file comment. Answers the fixture rows' ids (and New Message's people). */
export function fixture(context: DebugContext, params: Json): Json {
  const { debug, store, nav } = context;
  const intro = params.intro;
  if (intro === "welcome" || intro === "askFocus") {
    debug.set({ intro });
    const snapshot = store.getSnapshot();
    const shown = snapshot.selected ? snapshot.conversations.get(snapshot.selected) : undefined;
    return { intro: shown?.kind === "chief" };
  }
  const size = int(params.new_message);
  if (size !== undefined) {
    const contacts = fixtureContacts(size);
    debug.set({ contacts });
    if (!nav.getSnapshot().compose?.shown) {
      nav.dismiss();
      nav.openCompose();
    }
    nav.requestFocus();
    return { rows: contacts.length };
  }
  const team = int(params.team);
  if (team !== undefined) debug.set({ contacts: fixtureContacts(team) });
  const look = ["width", "select", "search", "unread", "team", "filter_look"];
  const reseeds =
    params.count !== undefined ||
    params.chiefs !== undefined ||
    params.channels !== undefined ||
    !look.some((key) => params[key] !== undefined);
  if (reseeds) {
    const count = clamp(int(params.count) ?? 5, 0, FIXTURE_NAMES.length);
    const pinned = clamp(int(params.pinned) ?? 3, 0, count);
    const chiefs = (Array.isArray(params.chiefs) ? params.chiefs : []).flatMap((entry) => {
      const { id, name } = record(entry);
      return typeof id === "string" && typeof name === "string" ? [{ id, name }] : [];
    });
    const channels = (Array.isArray(params.channels) ? params.channels : []).filter(
      (title): title is string => typeof title === "string",
    );
    debug.set({
      rows: fixtureRows({ count, pinned, chiefs, channels }, store.getSnapshot().me, context.now()),
      selected: undefined,
    });
  }
  const width = typeof params.width === "number" && params.width > 0 ? params.width : undefined;
  if (width !== undefined) debug.set({ width });
  if (typeof params.unread === "boolean") context.setUnreadOnly(params.unread);
  if (typeof params.search === "boolean") context.dom.focusSearch(params.search);
  const select = int(params.select);
  if (select !== undefined) {
    // The index in the list as drawn (tiles, then rows), as the native debugLook read it.
    const target = items(context.model)[select];
    if (!target) return { error: "no such row" };
    debug.set({ selected: target.id });
  }
  return { rows: [...debug.getSnapshot().rows.keys()] };
}

/** `snapshot`: the list as drawn and the shown transcript's newest texts. */
export function snapshot(context: DebugContext, params: Json): Json {
  const state = context.store.getSnapshot();
  const limit = clamp(int(params.limit) ?? 10, 1, 200);
  const composing = context.nav.getSnapshot().compose?.shown === true;
  return {
    list: items(context.model).map((item) => ({
      id: item.id,
      title: item.title,
      pinned: item.pinned,
      unread: item.unread,
      chief: item.conversation.kind === "chief" || item.peer?.chief === true,
    })),
    note: context.note ?? null,
    cloud: null,
    shown: composing ? null : (state.selected ?? null),
    open_thread: state.thread ?? null,
    transcript_tail: composing ? [] : texts(state, limit),
  };
}

/** The shown conversation's newest `limit` texts, oldest first, then my sends not shown yet. */
function texts(state: ReturnType<DebugContext["store"]["getSnapshot"]>, limit: number): string[] {
  const shown = state.messages.filter((message) => !message.retracted).map(messageText);
  const pending = state.pending.filter((entry) => entry.conversation === state.selected).map((entry) => entry.text);
  return [...shown, ...pending].slice(-limit);
}

/** `list`: the row menu's handlers, as the row's own menu runs them. */
export async function list(context: DebugContext, params: Json): Promise<Json> {
  const conversation = typeof params.conversation === "string" ? params.conversation : undefined;
  const item = conversation ? items(context.model).find((entry) => entry.id === conversation) : undefined;
  if (!conversation || !item) return { ok: false, error: "no such conversation in the Messages list" };
  const { store, messages, strings } = context;
  const handlers = {
    canPin: store.getSnapshot().inboxState,
    onSetPinned: (id: string, pinned: boolean) => void store.setPinned(id, pinned),
    onMarkRead: (id: string) => store.markConversationRead(id),
    onMarkUnread: (id: string) => void store.setMarkedUnread(id, true),
    onHostItem: (entry: Parameters<MessagesHost["perform"]>[0]) => void messages.perform(entry),
  };
  switch (params.op) {
    case "pin":
    case "unpin":
      return { ok: await store.setPinned(conversation, params.op === "pin") };
    case "unread":
      return { ok: await store.setMarkedUnread(conversation, true) };
    case "read":
      store.markConversationRead(conversation);
      return { ok: true };
    case "menu": {
      const host = await messages.menu("row", conversation).catch(() => []);
      const menu = rowMenu(item, handlers, host, strings);
      const titles = menu.map((entry) => entry.label);
      if (typeof params.item !== "string") return { ok: true, items: titles };
      const chosen = menu.find((entry) => entry.label === params.item);
      if (!chosen) return { ok: false, error: `no menu item ${params.item}`, items: titles };
      chosen.onSelect?.();
      return { ok: true, items: titles, performed: params.item };
    }
    default:
      return { ok: false, error: "op must be pin, unpin, unread, read or menu" };
  }
}

/** The open thread, as the native drive answered it. */
function threadReply(context: DebugContext, ok: boolean): Json {
  const state = context.store.getSnapshot();
  return {
    ok,
    open_thread: state.thread ?? null,
    thread_path: state.thread ? [state.thread] : [],
    thread_message: state.highlight ?? null,
  };
}

/** `drive`: the shown conversation through its own entry points (debug.home.drive). */
export async function drive(context: DebugContext, params: Json): Promise<Json> {
  const { store, nav, dom } = context;
  const state = store.getSnapshot();
  const composing = nav.getSnapshot().compose?.shown === true;
  if (!composing && (!state.selected || !state.conversations.has(state.selected)))
    return { error: "no Home conversation is shown" };
  switch (params.drive) {
    case "focus":
      return { ok: nav.focus() };
    case "type":
      if (!nav.focus()) return { error: "no field" };
      return { ok: dom.insertText(typeof params.text === "string" ? params.text : "") };
    case "send": {
      // The send button the person clicks (Return's path): a refused send is never ok.
      const sent = dom.click(".hm-detail .mt-send");
      if (sent === "missing") return { ok: false, refused: "empty" };
      if (sent === "disabled") return { ok: false, refused: "offline" };
      return { ok: true };
    }
    case "texts":
      return { ok: true, texts: texts(state, clamp(int(params.limit) ?? 50, 1, 500)), statusLine: null };
    case "typing":
      return { ok: state.typing.length > 0, typing: [...state.typing] };
    case "thread": {
      // The newest message with replies (a "N Replies" click).
      const roots = new Set(state.messages.flatMap((message) => threadOf(message) ?? []));
      for (const root of state.threadStats.keys()) roots.add(root);
      const newest = [...state.messages].reverse().find((message) => roots.has(message.id));
      if (newest) await store.openThread(newest.id);
      return threadReply(context, true);
    }
    case "escape":
      if (store.getSnapshot().thread) await store.openThread(undefined);
      return threadReply(context, true);
    case "reply": {
      // Reply… on the newest text bubble (mine, or another's): its thread opens.
      const me = state.me?.id;
      const mine = params.mine === true;
      const newest = [...state.messages]
        .reverse()
        .find(
          (message) =>
            !message.retracted &&
            message.parts.some((part) => part.type === "text") &&
            (message.author === me) === mine,
        );
      if (newest) await store.openThread(threadOf(newest) ?? newest.id);
      return threadReply(context, true);
    }
    case "thread_state":
      return threadReply(context, true);
    default:
      return {
        error:
          "on the Messages page, action must be focus, type, send, texts, typing, thread, escape, reply or thread_state",
      };
  }
}

/** One debug call. */
export async function debugCommand(context: DebugContext, params: unknown): Promise<Json> {
  const raw = record(params);
  switch (raw.action) {
    case "fixture":
      return fixture(context, raw);
    case "snapshot":
      return snapshot(context, raw);
    case "list":
      return list(context, raw);
    case "drive":
      return drive(context, raw);
    default:
      return { error: "action must be fixture, snapshot, list or drive" };
  }
}

/** Serves `home.messages.debug` while the page is mounted, with the latest committed context. */
export function useDebugCommands(host: PageClient | null, context: DebugContext) {
  const latest = useRef(context);
  useLayoutEffect(() => {
    latest.current = context;
  });
  useEffect(() => {
    if (!host) return;
    return host.handle(DEBUG_OP, (params: unknown) => debugCommand(latest.current, params));
  }, [host]);
}
