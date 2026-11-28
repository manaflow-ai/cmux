// ⌥⌘S opens Share poster… on the chat's last finished turn, as the ••• menu's row does. A page
// key, not an app action: no app action takes ⌥⌘S, so the web view gets it. One listener while the
// pane shows a chat that can make a poster; it goes with the pane or when that stops.
import { useEffect, useRef } from "react";

/// Whether `event` is ⌥⌘S (by key position: ⌥ changes the letter it types).
export const isPosterKey = (event: Pick<KeyboardEvent, "code" | "metaKey" | "altKey" | "shiftKey" | "ctrlKey">) =>
  event.code === "KeyS" && event.metaKey && event.altKey && !event.shiftKey && !event.ctrlKey;

/// Calls `open` on ⌥⌘S while `enabled` and `ready()` (a turn has finished).
export function usePosterShortcut(enabled: boolean, ready: () => boolean, open: () => void): void {
  const latest = useRef({ ready, open });
  useEffect(() => {
    latest.current = { ready, open };
  });
  useEffect(() => {
    if (!enabled) return;
    const onKey = (event: KeyboardEvent) => {
      if (!isPosterKey(event) || event.defaultPrevented || !latest.current.ready()) return;
      event.preventDefault();
      latest.current.open();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [enabled]);
}
