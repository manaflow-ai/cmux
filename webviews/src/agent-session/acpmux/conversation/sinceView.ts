// How "New since you looked" (SinceDivider.tsx) shows, the viewer's pick (Leo, 2026-11-10: "you can
// have the collapsed view. You can have the expanded view. You can have, like, right click to just
// hide it completely. You can right click to bring it back"). `expanded`, the default, is the line
// with its turn count and the recap under it, and the top bar with both; `collapsed` is the line and
// its New tag alone, and a small New tab at the top; `hidden` draws neither. A click on the line
// switches expanded and collapsed; its right-click (and the top bar's) picks one or hides it, and
// the chat menu's Show New Since You Looked brings it back. Kept in localStorage across chats, panes
// and launches, in step by the `storage` event, as the composer's look is (composerLook.ts).
import { useSyncExternalStore } from "react";

export const SINCE_VIEWS = ["expanded", "collapsed", "hidden"] as const;
export type SinceViewPick = (typeof SINCE_VIEWS)[number];

export const DEFAULT_SINCE_VIEW: SinceViewPick = "expanded";
const KEY = "cmux.agentPane.since.view";

function parse(value: unknown): SinceViewPick {
  return value === "collapsed" || value === "hidden" ? value : DEFAULT_SINCE_VIEW;
}

/// The page's copy, for a page with no storage; storage's when there is one.
let fallback: SinceViewPick = DEFAULT_SINCE_VIEW;
const listeners = new Set<() => void>();

export function sinceView(): SinceViewPick {
  try {
    return globalThis.localStorage ? parse(globalThis.localStorage.getItem(KEY)) : fallback;
  } catch {
    return fallback;
  }
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    // A null key is the storage cleared (localStorage.clear()): the pick is back to the default.
    if (event.key === KEY || event.key === null) listener();
  };
  globalThis.addEventListener?.("storage", onStorage);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", onStorage);
  };
}

export function setSinceView(pick: SinceViewPick): void {
  fallback = parse(pick);
  try {
    globalThis.localStorage?.setItem(KEY, fallback);
  } catch {
    // Storage off: the page's copy still holds it.
  }
  for (const listener of listeners) listener();
}

export function useSinceView(): SinceViewPick {
  return useSyncExternalStore(subscribe, sinceView, sinceView);
}
