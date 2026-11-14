// A hidden chat page keeps no transcript (CMUX-571, Leo 2026-11-12: "infinite everything feels like nothing").
// Every agent chat tab is its own page in one shared renderer, and a tab that is not shown kept its whole drawn
// transcript: the rows' DOM, their styles and layout, the rows' prepared text and measured heights, and the React
// tree over them, about as much as the shown chat (chat-pages-memory.bench.ts HIDDEN=1). A page hidden for
// DORMANT_AFTER_MS lets the transcript go (App.tsx renders none); the chat's records stay in the client, and the
// place the reader left it at is kept, so showing the page draws the transcript again at that place before the
// first frame it shows (the show is applied in `flushSync`, inside the `visibilitychange` that announces it).
import { useSyncExternalStore } from "react";
import { flushSync } from "react-dom";

/// How long a page stays hidden before its transcript goes. Shorter than `browser.freezeHiddenTabs` (30 s by
/// default), after which a frozen page runs no script and could not let it go; long enough that a tab passed
/// over on the way to another keeps its transcript.
export const DORMANT_AFTER_MS = 5_000;

type Store = {
  dormant: boolean;
  /// Run right before the transcript goes, while it is still drawn (App.tsx keeps the reader's place).
  before: Set<() => void>;
  timer?: ReturnType<typeof setTimeout>;
  listeners: Set<() => void>;
  hooked: boolean;
};
const store: Store = { dormant: false, before: new Set(), listeners: new Set(), hooked: false };

function notify(): void {
  for (const listener of [...store.listeners]) listener();
}

function hidden(): boolean {
  return typeof document !== "undefined" && document.visibilityState === "hidden";
}

function arm(): void {
  clearTimeout(store.timer);
  store.timer = undefined;
  if (!hidden()) return;
  store.timer = setTimeout(() => {
    store.timer = undefined;
    if (!hidden() || store.dormant) return;
    for (const run of [...store.before]) run();
    store.dormant = true;
    notify();
  }, DORMANT_AFTER_MS);
}

function visibilityChanged(): void {
  if (hidden()) return arm();
  clearTimeout(store.timer);
  store.timer = undefined;
  if (!store.dormant) return;
  // Drawn before the page's first frame shows: the transcript is back in the frame the tab appears in.
  flushSync(() => {
    store.dormant = false;
    notify();
  });
}

function subscribe(listener: () => void): () => void {
  if (!store.hooked && typeof document !== "undefined") {
    store.hooked = true;
    document.addEventListener("visibilitychange", visibilityChanged);
    arm();
  }
  store.listeners.add(listener);
  return () => {
    store.listeners.delete(listener);
  };
}

const read = () => store.dormant;
const readServer = () => false;

/// Runs `run` right before the transcript goes (it is still mounted then); returns the removal.
export function beforeTranscriptDormant(run: () => void): () => void {
  store.before.add(run);
  return () => {
    store.before.delete(run);
  };
}

/// Whether the transcript is let go now, outside React (the chat's snapshot writer, chatSnapshot/live.ts).
export function transcriptIsDormant(): boolean {
  return store.dormant;
}

/// Whether the page has been hidden long enough that it draws no transcript.
export function useTranscriptDormant(): boolean {
  return useSyncExternalStore(subscribe, read, readServer);
}

/// Tests: the store as a fresh page has it.
export function resetTranscriptDormancy(): void {
  clearTimeout(store.timer);
  store.timer = undefined;
  store.dormant = false;
  if (store.hooked && typeof document !== "undefined")
    document.removeEventListener("visibilitychange", visibilityChanged);
  store.hooked = false;
}
