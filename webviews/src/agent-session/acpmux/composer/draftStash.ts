// Stash: the composer's draft put aside with one key (⌃S), the prompt emptied for something else,
// and the draft brought back (⌃S on an empty prompt, or a pick from the Stashed chip's list). Each
// chat holds a short stack, newest first. The stacks live in acpmux (`stash.rs`), not in the page:
// the pane's web views keep no storage past their page, and acpmux's stash outlives a reload, a new
// page and a relaunch. A chat is the composer's key: its session id, or a new chat's own key until
// it has one (`moveStash`). The page keeps each chat's list as acpmux last answered it; a list row's
// chips have no contents, and `readStashed` reads one draft whole. A draft leaves acpmux only once
// the composer holds it again (`dropStashed` after the restore), so nothing is lost in between.
import { useEffect, useState, useSyncExternalStore } from "react";
import { withoutInlineTokens, type ComposerAttachment } from "../attachments";

export type StashedDraft = {
  id: string;
  text: string;
  /// A list row's chips have no contents and its text is only the start; `readStashed`'s are whole.
  attachments: ComposerAttachment[];
  at: number;
};

/// How the page reaches acpmux's stash (direct.ts listStash, pushStash, getStash, dropStash, moveStash).
export type StashTransport = {
  list(chat: string): Promise<unknown>;
  push(chat: string, text: string, attachments: readonly ComposerAttachment[], replaces?: string): Promise<unknown>;
  get(chat: string, id: string): Promise<unknown>;
  drop(chat: string, id: string): Promise<unknown>;
  /// Moves `chat`'s whole stack onto `to`'s in one write (`stash_move`).
  move(chat: string, to: string): Promise<unknown>;
};

const NONE: readonly StashedDraft[] = [];
/// The most drafts one chat holds, as acpmux keeps (`stash.rs` STASH_LIMIT).
export const STASH_LIMIT = 5;
let transport: StashTransport | undefined;
const stacks = new Map<string, readonly StashedDraft[]>();
/// The chats a composer shows, read again when the transport comes.
const wanted = new Set<string>();
const listeners = new Set<() => void>();
const emit = () => {
  for (const listener of listeners) listener();
};
const setStack = (chat: string, list: readonly StashedDraft[]) => {
  if (list.length) stacks.set(chat, list);
  else stacks.delete(chat);
  emit();
};

/// One draft from acpmux's answer, or undefined when it is not one.
export function draftFrom(value: unknown): StashedDraft | undefined {
  if (!value || typeof value !== "object") return undefined;
  const { id, text, at, attachments } = value as Record<string, unknown>;
  if (typeof id !== "string" || typeof text !== "string" || typeof at !== "number") return undefined;
  return {
    id,
    text,
    at,
    attachments: Array.isArray(attachments)
      ? (attachments.filter((chip) => !!chip && typeof chip === "object") as ComposerAttachment[])
      : [],
  };
}

/// A list answer's drafts (`{drafts: [...]}`), malformed ones left out.
export function draftsFrom(value: unknown): StashedDraft[] {
  const list = value && typeof value === "object" ? (value as { drafts?: unknown }).drafts : undefined;
  return Array.isArray(list) ? list.flatMap((row) => draftFrom(row) ?? []) : [];
}

/// Connects the page to acpmux's stash (none: the pane closed). Another connection (a reconnect,
/// another machine's acpmux) starts from no stacks: the old one's drafts are never shown or brought
/// back, and its answers still on their way are dropped. Every shown chat is read again.
export function setStashTransport(next: StashTransport | undefined): void {
  if (next === transport) return;
  transport = next;
  if (stacks.size) {
    stacks.clear();
    emit();
  }
  if (!next) return;
  for (const chat of wanted) void refreshStash(chat).then(() => retryMoves(chat));
}

/// Pushes and drops begun or ended, per chat: a list read while one was out may not hold it.
const changes = new Map<string, number>();
const changed = (chat: string) => changes.set(chat, (changes.get(chat) ?? 0) + 1);

/// Reads `chat`'s stack from acpmux. A failed read keeps what the page had; an answer read while a
/// push or drop was out is dropped and the stack read again, so it never takes back a stash the
/// page already shows. Whether the page now holds what acpmux answered.
export function refreshStash(chat: string): Promise<boolean> {
  const link = transport;
  if (!link) return Promise.resolve(false);
  const at = changes.get(chat) ?? 0;
  return link.list(chat).then(
    (answer) => {
      if (link !== transport) return false;
      if (at !== (changes.get(chat) ?? 0)) return refreshStash(chat);
      setStack(chat, draftsFrom(answer));
      return true;
    },
    () => false,
  );
}

/// Puts the draft on top of `chat`'s stack in acpmux, in place of draft `replaces` when given (one
/// write: a full stack lets no other go). Nothing is stashed for an empty draft, nor when acpmux
/// does not take it (no connection, a refusal, a draft too large to answer whole): the composer
/// keeps the draft then. Whether it was stashed.
export async function stashDraft(
  chat: string,
  text: string,
  attachments: readonly ComposerAttachment[],
  replaces?: string,
): Promise<boolean> {
  const link = transport;
  if (!link || (!text.trim() && attachments.length === 0)) return false;
  changed(chat);
  try {
    const answer = await link.push(chat, text, attachments, replaces);
    const row = draftFrom((answer as { draft?: unknown } | undefined)?.draft);
    // A connection that changed meanwhile: the composer keeps the draft (the old acpmux has a copy).
    if (!row || link !== transport) return false;
    setStack(
      chat,
      [row, ...(stacks.get(chat) ?? NONE).filter((entry) => entry.id !== row.id && entry.id !== replaces)].slice(
        0,
        STASH_LIMIT,
      ),
    );
    return true;
  } catch {
    return false;
  } finally {
    changed(chat);
  }
}

/// Draft `id` of `chat`, whole (its chips' contents too); it stays stashed until `dropStashed`.
export async function readStashed(chat: string, id: string): Promise<StashedDraft | undefined> {
  const link = transport;
  if (!link) return undefined;
  try {
    const draft = draftFrom(((await link.get(chat, id)) as { draft?: unknown } | undefined)?.draft);
    return link === transport ? draft : undefined;
  } catch {
    return undefined;
  }
}

/// Removes draft `id` from `chat`'s stack, at once in the page. A drop acpmux does not take reads
/// the stack again, so the draft it still keeps shows again. Whether acpmux dropped it.
export async function dropStashed(chat: string, id: string): Promise<boolean> {
  const link = transport;
  if (!link) return false;
  setStack(
    chat,
    (stacks.get(chat) ?? NONE).filter((entry) => entry.id !== id),
  );
  changed(chat);
  const dropped = await link.drop(chat, id).then(
    () => true,
    () => false,
  );
  changed(chat);
  if (!dropped) void refreshStash(chat);
  return dropped;
}

/// Moves not yet done, by the chat they go to, each with the drafts it is to bring: tried again
/// when that chat shows or acpmux connects again, so a move that failed leaves no draft where no
/// composer looks. A move is done only once the chat's stack lists every one of its drafts (or is
/// full, the oldest let go): another acpmux (another machine), which holds none of them and moves
/// none, leaves it waiting for the one that does.
type PendingMove = { ids: Set<string>; read: boolean };
const moves = new Map<string, Map<string, PendingMove>>();
const moving = new Set<string>();

/// A new chat's stack follows it once it has a session. acpmux moves it in one write under its
/// lock (`stash_move`): no failure midway and no trimming of old chats loses a draft, and a move
/// tried again adds none twice.
export async function moveStash(from: string, to: string): Promise<void> {
  if (from === to) return;
  const sources = moves.get(to) ?? new Map<string, PendingMove>();
  if (!sources.has(from)) sources.set(from, { ids: new Set(), read: false });
  moves.set(to, sources);
  await moveNow(from, to);
}

async function moveNow(from: string, to: string): Promise<void> {
  const link = transport;
  if (!link || moving.has(from)) return;
  moving.add(from);
  try {
    // The drafts this acpmux holds for the new chat now, read on this connection.
    const pending = moves.get(to)?.get(from);
    if (pending && (await refreshStash(from))) {
      pending.read = true;
      for (const entry of stacks.get(from) ?? NONE) pending.ids.add(entry.id);
    }
    changed(from);
    changed(to);
    await link.move(from, to).catch(() => undefined);
    changed(from);
    changed(to);
    await Promise.all([refreshStash(from), refreshStash(to)]);
    const brought = new Set((stacks.get(to) ?? NONE).map((entry) => entry.id));
    const sources = moves.get(to);
    const whole =
      link === transport &&
      !!pending?.read &&
      !(stacks.get(from) ?? NONE).length &&
      (brought.size >= STASH_LIMIT || [...pending.ids].every((id) => brought.has(id)));
    if (whole && sources) {
      sources.delete(from);
      if (!sources.size) moves.delete(to);
    }
  } finally {
    moving.delete(from);
  }
}

/// The moves into `chat` a failure left unfinished, tried again (as `chat` shows, and as acpmux
/// connects again).
export function retryMoves(chat: string): Promise<void> {
  return Promise.all([...(moves.get(chat)?.keys() ?? [])].map((from) => moveNow(from, chat))).then(() => undefined);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// `chat`'s stack, newest first, read from acpmux when the chat shows.
export function useStash(chat: string): readonly StashedDraft[] {
  useEffect(() => {
    wanted.add(chat);
    void refreshStash(chat).then(() => retryMoves(chat));
    return () => void wanted.delete(chat);
  }, [chat]);
  return useSyncExternalStore(
    subscribe,
    () => stacks.get(chat) ?? NONE,
    () => NONE,
  );
}

/// The tab this page is (the handshake's `tab`, kept by the app across a relaunch), so a new chat's
/// stack has a key that outlives the page: `new-tab:<tab>`. Before it is known (an older app, the
/// gallery) a composer has a key of its own, and its stack moves to the tab's once it is known.
let paneTab: string | undefined;
const tabListeners = new Set<() => void>();
export function setStashTab(tab: string | undefined): void {
  if (tab === paneTab) return;
  paneTab = tab;
  for (const listener of tabListeners) listener();
}
const subscribeTab = (listener: () => void) => {
  tabListeners.add(listener);
  return () => void tabListeners.delete(listener);
};
const ownKey = () => `new-${globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`}`;

/// The New Tab page's stack, one for every New Tab: it never moves into a chat.
export const NEW_TAB_STASH = "new-tab-page";

/// The stash key of a composer's new chat (no session yet).
export function useNewChatStash(): string {
  const [own] = useState(ownKey);
  const tab = useSyncExternalStore(
    subscribeTab,
    () => paneTab,
    () => undefined,
  );
  return tab ? `new-tab:${tab}` : own;
}

/// The stack the page holds for `chat` now.
export const stashedNow = (chat: string): readonly StashedDraft[] => stacks.get(chat) ?? NONE;

/// Tests: forget the page's stacks and use `next` as acpmux.
export function resetStashForTests(next?: StashTransport): void {
  paneTab = undefined;
  stacks.clear();
  wanted.clear();
  changes.clear();
  moves.clear();
  moving.clear();
  transport = next;
}

/// A stashed draft on one line, for its row in the list.
export function stashPreview(entry: StashedDraft): string {
  return withoutInlineTokens(entry.text).replace(/\s+/g, " ").trim().slice(0, 120);
}
