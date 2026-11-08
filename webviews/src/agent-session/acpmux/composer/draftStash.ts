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

/// How the page reaches acpmux's stash (direct.ts listStash, pushStash, getStash, dropStash).
export type StashTransport = {
  list(chat: string): Promise<unknown>;
  push(chat: string, text: string, attachments: readonly ComposerAttachment[], replaces?: string): Promise<unknown>;
  get(chat: string, id: string): Promise<unknown>;
  drop(chat: string, id: string): Promise<unknown>;
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
  for (const chat of wanted) void refreshStash(chat);
}

/// Reads `chat`'s stack from acpmux. A failed read keeps what the page had.
export function refreshStash(chat: string): Promise<void> {
  const link = transport;
  if (!link) return Promise.resolve();
  return link.list(chat).then(
    (answer) => {
      if (link === transport) setStack(chat, draftsFrom(answer));
    },
    () => undefined,
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

/// Removes draft `id` from `chat`'s stack, at once in the page.
export async function dropStashed(chat: string, id: string): Promise<void> {
  const link = transport;
  if (!link) return;
  setStack(
    chat,
    (stacks.get(chat) ?? NONE).filter((entry) => entry.id !== id),
  );
  await link.drop(chat, id).catch(() => undefined);
}

/// A new chat's stack follows it once it has a session. Every draft is read whole first, so a push
/// under the session that lets acpmux trim old chats (the new chat's own file among them) loses
/// none; each leaves the new chat's stack only once it is stashed under the session.
export async function moveStash(from: string, to: string): Promise<void> {
  if (from === to || !transport) return;
  await refreshStash(from);
  const whole: StashedDraft[] = [];
  for (const row of [...(stacks.get(from) ?? NONE)].reverse()) {
    const entry = await readStashed(from, row.id);
    if (entry) whole.push(entry);
  }
  for (const entry of whole) if (await stashDraft(to, entry.text, entry.attachments)) await dropStashed(from, entry.id);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// `chat`'s stack, newest first, read from acpmux when the chat shows.
export function useStash(chat: string): readonly StashedDraft[] {
  useEffect(() => {
    wanted.add(chat);
    void refreshStash(chat);
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
  transport = next;
}

/// A stashed draft on one line, for its row in the list.
export function stashPreview(entry: StashedDraft): string {
  return withoutInlineTokens(entry.text).replace(/\s+/g, " ").trim().slice(0, 120);
}
