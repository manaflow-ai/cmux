import { useSyncExternalStore } from "react";

/// How an inbox thread's line opens to its whole thread (InboxNoticeCard.tsx). Shut, every look shows
/// the newest message's text under the line. `inline`, the default: opened, the card holds every
/// message of the thread, oldest first, each under its sender and time. `drill`, a gallery version
/// kept beside it (InboxNotice.gallery.ts), as the Background tasks panel drills in: opened, the card
/// holds a row per message (sender, time, first line) under a back control, and a row opens that
/// message whole under its own back control. The native host sends no value, so the default holds.
export type InboxThreadLook = "inline" | "drill";

const LOOKS: readonly InboxThreadLook[] = ["inline", "drill"];

let current: InboxThreadLook = "inline";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureInboxThreadLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "inline";
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The look now.
export const useInboxThreadLook = (): InboxThreadLook => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The look now, outside React (the row estimator, model.ts).
export const inboxThreadLook = (): InboxThreadLook => current;
