// Each agent chat's place on the detail ladder (chatDetail.ts): Messages, Normal, Thinking, Verbose.
// A chat keeps its own level here (localStorage, by acpmux session); a chat with none follows the
// setting `agentPane.display.detail` (chatDisplay.ts), which the chat menu's "Make … the default"
// writes. Rows read the level once from their providers' context (PresentationContext and the
// disclosure view), so a streamed token reads nothing new and a switch draws the rows on screen once,
// without the fold's animation.
//
// The two per-chat maps the ladder replaced still read: a chat the old Presentation menu put in
// Messages is at Messages, else its old Transcript View carries over, else a chat set to Transcript
// is at Normal. A new pick writes only the new map, which wins over both.
import { useSyncExternalStore } from "react";
import { DETAIL_KEY, isChatDetail, isTranscriptView, type ChatDetail } from "../chatDetail";
import { changeChatDisplay, defaultChatDetail, useDefaultChatDetail } from "../chatDisplay";

const STORAGE_KEY = "cmux.acpmux.detail";
/// The maps of the two old knobs, read under the new one.
const LEGACY_PRESENTATION_KEY = "cmux.acpmux.presentation";
const LEGACY_VIEW_KEY = "cmux.acpmux.transcriptView";
const KEYS = new Set([STORAGE_KEY, LEGACY_PRESENTATION_KEY, LEGACY_VIEW_KEY]);
/// The chats whose own level is kept; the oldest choice goes first.
const LIMIT = 200;

let own: Map<string, ChatDetail> | undefined;
/// The new map as this page last wrote or read it (storage refused or unreadable keeps it here).
let ownEntries: Map<string, Entry> | undefined;
/// A chat's entry in the new map: its level, or null for "follows the default" (it hides an old map's
/// choice for that chat).
type Entry = ChatDetail | null;
/// The choices storage refused: this page's only copy, laid over every read of storage and saved with
/// the next write that succeeds.
const unsaved = new Map<string, Entry>();
const listeners = new Set<() => void>();

function readMap(storage: Storage, key: string): Record<string, unknown> {
  const value = JSON.parse(storage.getItem(key) ?? "null") as unknown;
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

/// The new map alone, as stored now; undefined when storage cannot be read.
function storedOwn(): Map<string, Entry> | undefined {
  try {
    const storage = globalThis.localStorage;
    if (!storage) return undefined;
    const levels = new Map<string, Entry>();
    for (const [sessionId, level] of Object.entries(readMap(storage, STORAGE_KEY)))
      if (isChatDetail(level) || level === null) levels.set(sessionId, level);
    return levels;
  } catch {
    // Private windows, test DOMs and full storage keep the choices for this page only.
    return undefined;
  }
}

/// The old maps' choices for chats the new map does not name.
function legacy(): Map<string, ChatDetail> {
  const levels = new Map<string, ChatDetail>();
  try {
    const storage = globalThis.localStorage;
    if (!storage) return levels;
    const presentations = readMap(storage, LEGACY_PRESENTATION_KEY);
    for (const [sessionId, view] of Object.entries(readMap(storage, LEGACY_VIEW_KEY)))
      if (isTranscriptView(view)) levels.set(sessionId, view);
    for (const [sessionId, presentation] of Object.entries(presentations)) {
      if (presentation === "messages") levels.set(sessionId, "messages");
      else if (presentation === "transcript" && !levels.has(sessionId)) levels.set(sessionId, "normal");
    }
  } catch {
    // Nothing old to read.
  }
  return levels;
}

/// What storage holds now (else this page's last copy): the old choices under the new ones, with the
/// choices storage refused laid over it.
function reread(): Map<string, ChatDetail> {
  const all = legacy();
  for (const [sessionId, level] of entries()) {
    all.delete(sessionId);
    if (level) all.set(sessionId, level);
  }
  return all;
}

/// The new map now: storage's (else this page's last copy), with the refused choices over it.
function entries(): Map<string, Entry> {
  const mine = storedOwn() ?? new Map(ownEntries ?? []);
  for (const [sessionId, level] of unsaved) {
    mine.delete(sessionId);
    mine.set(sessionId, level);
  }
  return mine;
}

/// The choices. While a level is drawn the storage listener keeps this page's copy current; with none
/// drawn nothing hears another pane, so a read then reads storage again.
function load(): Map<string, ChatDetail> {
  if (!own || listeners.size === 0) own = reread();
  return own;
}

/// Writes one chat's choice (or its removal) over what the new map holds now, not this page's copy:
/// another pane's choices made since this page read them stay, and so do the ones storage refused. A
/// removal is written as the default's level when an old map still names the chat, so the old choice
/// does not come back.
function write(sessionId: string, level: ChatDetail | undefined): void {
  const mine = entries();
  mine.delete(sessionId);
  // A removal keeps a null while an old map names the chat, so its old choice does not come back.
  if (level) mine.set(sessionId, level);
  else if (legacy().has(sessionId)) mine.set(sessionId, null);
  while (mine.size > LIMIT) mine.delete(mine.keys().next().value!);
  ownEntries = mine;
  try {
    const storage = globalThis.localStorage;
    if (!storage) throw new Error("no storage");
    storage.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(mine)));
    unsaved.clear();
  } catch {
    // The in-memory choice still lasts for this page.
    unsaved.set(sessionId, level ?? null);
  }
  own = reread();
}

// Another pane (another page on the same origin) changed a chat's level: read it again. Heard only
// while a level is drawn (`subscribe`), so loading this module adds no listener.
function onStorage(event: StorageEvent): void {
  if (event.key !== null && !KEYS.has(event.key)) return;
  own = reread();
  for (const listener of listeners) listener();
}

/// Set while a switch opens or closes the rows on screen: their folds snap instead of playing
/// (useAnchoredCollapse.ts). Cleared on the next frame, after the switch has drawn.
let switching = false;
function snapNextDraw(): void {
  switching = true;
  const clear = () => {
    switching = false;
  };
  if (typeof globalThis.requestAnimationFrame === "function") globalThis.requestAnimationFrame(clear);
  else setTimeout(clear, 0);
}

/// Whether a fold plays now: not while a level switch draws.
export const foldPlays = (): boolean => !switching;

function notify(): void {
  snapNextDraw();
  for (const listener of listeners) listener();
}

/// The first level drawn adds the storage listener (and reads what changed while none was heard); the
/// last one gone removes it.
const subscribe = (listener: () => void) => {
  if (listeners.size === 0 && typeof globalThis.addEventListener === "function") {
    globalThis.addEventListener("storage", onStorage);
    own = reread();
  }
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) globalThis.removeEventListener?.("storage", onStorage);
  };
};

/// The chat's level: its own, else the default setting.
export const chatDetailOf = (sessionId: string | undefined): ChatDetail =>
  (sessionId ? load().get(sessionId) : undefined) ?? defaultChatDetail();

/// Whether the chat has a level of its own (picked in its menu), even one equal to the default.
export const hasOwnChatDetail = (sessionId: string | undefined): boolean =>
  sessionId !== undefined && load().has(sessionId);

/// The chat's level as a hook.
export function useChatDetail(sessionId: string | undefined): ChatDetail {
  const fallback = useDefaultChatDetail();
  const mine = useSyncExternalStore(
    subscribe,
    () => (sessionId ? load().get(sessionId) : undefined),
    () => undefined,
  );
  return mine ?? fallback;
}

/// The chat menu's Messages, Normal, Thinking or Verbose: this chat only.
export function setChatDetail(sessionId: string, level: ChatDetail): void {
  if (load().get(sessionId) === level && storedOwn()?.get(sessionId) === level) return;
  write(sessionId, level);
  notify();
}

/// "Make … the default": every chat without a level of its own shows `level`, this one included (it
/// follows the default from now on). Normal is the setting's default, so it removes the key.
export function makeChatDetailDefault(sessionId: string | undefined, level: ChatDetail): void {
  snapNextDraw();
  changeChatDisplay(DETAIL_KEY, level === "normal" ? null : level);
  if (sessionId && load().has(sessionId)) write(sessionId, undefined);
  for (const listener of listeners) listener();
}

/// Test and gallery reset: every chat follows the default again.
export function resetChatDetails(): void {
  own = new Map();
  ownEntries = new Map();
  unsaved.clear();
  try {
    for (const key of KEYS) globalThis.localStorage?.removeItem(key);
  } catch {
    // Storage keeps them: this page drops each one it still holds.
    for (const sessionId of reread().keys()) unsaved.set(sessionId, null);
  }
  for (const listener of listeners) listener();
}
