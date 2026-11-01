import { useSyncExternalStore } from "react";

/// How an inbox notice of two or more threads draws (InboxNoticeCard.tsx). `group`, the default: one
/// line, "N messages from M sessions" and the senders, that opens to a received line per thread, as
/// the waiting messages' group draws (PendingMessagesCard.tsx). The others are gallery versions kept
/// beside it (InboxNotice.gallery.ts): `lines`, a received line per thread with no head; `card`, the
/// threads' lines always shown in one quiet bordered card. A notice of one thread is its line alone
/// in every look. The native host sends no value, so the default holds there.
export type InboxNoticeLook = "group" | "lines" | "card";

const LOOKS: readonly InboxNoticeLook[] = ["group", "lines", "card"];
let current: InboxNoticeLook = "group";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureInboxNoticeLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "group";
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
export const useInboxNoticeLook = (): InboxNoticeLook => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The look now, outside React (the row estimator, model.ts).
export const inboxNoticeLook = (): InboxNoticeLook => current;
