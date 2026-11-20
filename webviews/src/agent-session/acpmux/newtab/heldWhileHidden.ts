// A New Tab page nobody sees does no work over the chats (Leo, 2026-11-18: "Why should non visible
// thing even affect the renderer thread anyways?"). A tab's New Tab behind another tab and the
// prewarmed spare both read the whole list: the chat cards (`recentSessions`, `indexChildren`), the
// leaders row (`leaders`), the needs-you cards and the folder lists. Each list change made them run
// again over every chat, for a page no one looked at. Hidden, the page keeps the value it last drew
// with, so every memo over it stays put; shown again, it reads the newest once.
//
// Hidden is the document's: a tab in the background, or a page the host says nobody sees
// (`window.cmuxPageSeen(false)`, shared/pageSeen.ts), which reads as hidden and fires
// `visibilitychange`.
import { useRef, useSyncExternalStore } from "react";

function subscribe(onChange: () => void): () => void {
  if (typeof document === "undefined") return () => {};
  document.addEventListener("visibilitychange", onChange);
  return () => document.removeEventListener("visibilitychange", onChange);
}

const seen = (): boolean => typeof document === "undefined" || document.visibilityState !== "hidden";

/// Whether someone sees the page, kept as it changes.
export function usePageSeen(): boolean {
  return useSyncExternalStore(subscribe, seen, () => true);
}

/// `value` while the page is seen; while hidden, the value it had when it was last seen (or its
/// first, for a page that opens hidden), so nothing that depends on it runs again. A ref, not state:
/// a seen page's change renders once, not twice.
export function useHeldWhileHidden<T>(value: T): T {
  const visible = usePageSeen();
  const held = useRef(value);
  if (visible) held.current = value;
  return held.current;
}
