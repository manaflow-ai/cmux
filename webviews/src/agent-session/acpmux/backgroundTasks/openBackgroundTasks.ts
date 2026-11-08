// How a background command's row elsewhere (Session Info's Background tasks list) opens it rendered:
// the chat's Background tasks panel (BackgroundTasksPanel.tsx), on that command's card, open, with
// its command and its output, instead of a bare terminal tab (Leo, 2026-11-07: "only showing the
// terminal thing, I don't think is very useful"). Open in terminal stays inside the card.
//
// The panel is usually another page: the chat's Background tasks tab on its right (backgroundPane.ts),
// which the app only opens or focuses and tells nothing more. So the command to open travels as a
// request in localStorage, the way a chat's presentation reaches its other panes
// (conversation/presentation.ts): the panel's page reads it when it loads (a tab just opened) and on
// the `storage` event (a tab already open); the page that asked hears it at once (a panel kept in its
// own column). A request is stamped with its time: one older than `FOCUS_FRESH_MS` when a panel
// first draws is history (a panel opened later from the ⋯ menu), never acted on.
import { createContext, useSyncExternalStore } from "react";

/// Opens the panel on the command its tool call `toolCallId` started. App.tsx provides it; unset (the
/// gallery, Quick Chat), a row opens what it opened before.
export const OpenBackgroundTasks = createContext<((toolCallId: string) => void) | undefined>(undefined);

/// A request to open the panel on one command: its chat, the call that started it, and when.
export type BackgroundFocus = { sessionId: string; toolCallId: string; at: number };

/// How old a request may be when a panel first draws and still opens it: a just-opened tab loads
/// within this.
export const FOCUS_FRESH_MS = 30_000;

const KEY = "cmux.acpmux.backgroundFocus";
const listeners = new Set<() => void>();

const parse = (raw: string | null | undefined): BackgroundFocus | undefined => {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<BackgroundFocus>;
    return typeof value.sessionId === "string" && typeof value.toolCallId === "string" && typeof value.at === "number"
      ? { sessionId: value.sessionId, toolCallId: value.toolCallId, at: value.at }
      : undefined;
  } catch {
    return undefined;
  }
};

const stored = () => {
  try {
    return parse(globalThis.localStorage?.getItem(KEY));
  } catch {
    return undefined;
  }
};

let current = stored();

const notify = () => {
  for (const listener of listeners) listener();
};

/// Asks the chat's panel, in this page or another, to open on `toolCallId`'s command.
export function requestBackgroundFocus(sessionId: string, toolCallId: string, at = Date.now()) {
  // Two clicks in the same millisecond still read as two requests.
  current = { sessionId, toolCallId, at: Math.max(at, (current?.at ?? 0) + 1) };
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(current));
  } catch {
    // No storage: a panel in this page still hears it.
  }
  notify();
}

// Another page (Session Info in the chat's tab) asked: read it again.
if (typeof globalThis.addEventListener === "function")
  globalThis.addEventListener("storage", (event: StorageEvent) => {
    if (event.key !== KEY && event.key !== null) return;
    current = stored();
    notify();
  });

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The latest request for chat `sessionId`'s panel, if any. It changes only on a request, so the page
/// draws again only then.
export function useBackgroundFocus(sessionId: string | undefined): BackgroundFocus | undefined {
  const focus = useSyncExternalStore(subscribe, snapshot, snapshot);
  return focus && focus.sessionId === sessionId ? focus : undefined;
}
