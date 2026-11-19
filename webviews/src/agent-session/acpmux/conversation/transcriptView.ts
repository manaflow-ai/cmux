// The transcript's view, Claude Code desktop's Transcript view (Leo, 2026-10-29: "i like these kinds
// of settings from claude code desktop..."): Normal is the compact transcript, Thinking also opens
// every thought, Verbose also opens every tool's output. A view only changes what opens by default
// (transcriptDisclosure.tsx `useTranscriptDisclosure`, ThoughtRow.tsx), never how a row draws.
//
// Each chat keeps its own view here (localStorage, by acpmux session); a chat with none follows the
// setting `agentPane.display.transcriptView` (chatDisplay.ts), which the chat menu's "Make … the
// default" writes. Rows read the view once from the disclosure provider's context, so a streamed
// token reads nothing new and a switch draws the rows on screen once, without the fold's animation.
import { useSyncExternalStore } from "react";
import {
  TRANSCRIPT_VIEW_KEY,
  changeChatDisplay,
  defaultTranscriptView,
  useDefaultTranscriptView,
  type TranscriptView,
} from "../chatDisplay";

export { TRANSCRIPT_VIEWS, isTranscriptView, type TranscriptView } from "../chatDisplay";

const STORAGE_KEY = "cmux.acpmux.transcriptView";
/// The chats whose own view is kept; the oldest choice goes first.
const LIMIT = 200;

let own: Map<string, TranscriptView> | undefined;
/// Set when a choice could not be saved: this page's copy is then the only one, never read over.
let unsaved = false;
const listeners = new Set<() => void>();

/// The choices as stored now; undefined when storage cannot be read.
function stored(): Map<string, TranscriptView> | undefined {
  try {
    const value = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null") as unknown;
    const views = new Map<string, TranscriptView>();
    if (value && typeof value === "object")
      for (const [sessionId, view] of Object.entries(value as Record<string, unknown>))
        if (view === "normal" || view === "thinking" || view === "verbose") views.set(sessionId, view);
    return views;
  } catch {
    // Private windows, test DOMs and full storage keep the choices for this page only.
    return undefined;
  }
}

/// The choices. While a view is drawn the storage listener keeps this page's copy current; with none
/// drawn nothing hears another pane, so a read then reads storage again.
function load(): Map<string, TranscriptView> {
  if (!own || (listeners.size === 0 && !unsaved)) own = stored() ?? own ?? new Map();
  return own;
}

/// Writes one chat's choice (or its removal) over what storage holds now, not this page's copy:
/// another pane's choices made since this page read them stay.
function write(sessionId: string, view: TranscriptView | undefined): void {
  const all = stored() ?? load();
  all.delete(sessionId);
  if (view) all.set(sessionId, view);
  while (all.size > LIMIT) all.delete(all.keys().next().value!);
  own = all;
  try {
    const storage = globalThis.localStorage;
    storage?.setItem(STORAGE_KEY, JSON.stringify(Object.fromEntries(all)));
    unsaved = !storage;
  } catch {
    // The in-memory choice still lasts for this page.
    unsaved = true;
  }
}

// Another pane (another page on the same origin) changed a chat's view: read it again. Heard only
// while a view is drawn (`subscribe`), so loading this module adds no listener.
function onStorage(event: StorageEvent): void {
  if (event.key !== STORAGE_KEY && event.key !== null) return;
  own = stored() ?? own;
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

/// Whether a fold plays now: not while a view switch draws.
export const foldPlays = (): boolean => !switching;

function notify(): void {
  snapNextDraw();
  for (const listener of listeners) listener();
}

/// The first view drawn adds the storage listener (and reads what changed while none was heard); the
/// last one gone removes it.
const subscribe = (listener: () => void) => {
  if (listeners.size === 0 && typeof globalThis.addEventListener === "function") {
    globalThis.addEventListener("storage", onStorage);
    if (!unsaved) own = stored() ?? own;
  }
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) globalThis.removeEventListener?.("storage", onStorage);
  };
};

/// The chat's view: its own, else the default setting.
export const transcriptViewOf = (sessionId: string | undefined): TranscriptView =>
  (sessionId ? load().get(sessionId) : undefined) ?? defaultTranscriptView();

/// Whether the chat has a view of its own (picked in its menu), even one equal to the default.
export const hasOwnTranscriptView = (sessionId: string | undefined): boolean =>
  sessionId !== undefined && load().has(sessionId);

/// The chat's view as a hook (the disclosure provider reads it once for its rows).
export function useTranscriptView(sessionId: string | undefined): TranscriptView {
  const fallback = useDefaultTranscriptView();
  const mine = useSyncExternalStore(
    subscribe,
    () => (sessionId ? load().get(sessionId) : undefined),
    () => undefined,
  );
  return mine ?? fallback;
}

/// The chat menu's Normal, Thinking or Verbose: this chat only.
export function setTranscriptView(sessionId: string, view: TranscriptView): void {
  if (load().get(sessionId) === view && stored()?.get(sessionId) === view) return;
  write(sessionId, view);
  notify();
}

/// "Make … the default": every chat without a view of its own shows `view`, this one included (it
/// follows the default from now on). Normal is the setting's default, so it removes the key.
export function makeTranscriptViewDefault(sessionId: string | undefined, view: TranscriptView): void {
  if (sessionId && load().has(sessionId)) write(sessionId, undefined);
  snapNextDraw();
  changeChatDisplay(TRANSCRIPT_VIEW_KEY, view === "normal" ? null : view);
  for (const listener of listeners) listener();
}

/// Test and gallery reset: every chat follows the default again.
export function resetTranscriptViews(): void {
  own = new Map();
  try {
    const storage = globalThis.localStorage;
    storage?.removeItem(STORAGE_KEY);
    unsaved = !storage;
  } catch {
    // Nothing to persist.
    unsaved = true;
  }
  for (const listener of listeners) listener();
}
