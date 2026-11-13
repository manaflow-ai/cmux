import { useSyncExternalStore } from "react";

/// How another agent's message draws shut (IncomingMessageCard.tsx `IncomingMessageLine`). `line`,
/// the default: one tool-row line, its sender then its first line, that opens to the whole message
/// (Leo, 2026-11-07: "They should look basically the same as the other ones"). `card`, a gallery
/// version kept beside it (InboxThread.gallery.tsx), as an inbox thread draws (InboxNoticeCard.tsx):
/// its words under the line shut too, cut past eight lines with Show more (Leo, 2026-11-09: "we
/// should keep going further into the whole messaging system type situation"). The native host
/// sends no value, so the default holds there.
export type ReceivedLook = "line" | "card";

const LOOKS: readonly ReceivedLook[] = ["line", "card"];

let current: ReceivedLook = "line";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureReceivedLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "line";
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
export const useReceivedLook = (): ReceivedLook => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The look now, outside React (the row estimator, model.ts).
export const receivedLook = (): ReceivedLook => current;
