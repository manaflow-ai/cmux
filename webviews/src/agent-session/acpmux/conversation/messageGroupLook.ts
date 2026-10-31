import { useSyncExternalStore } from "react";

/// How a group of messages to other agents draws its rows (MessageGroupRow.tsx). `card`, the
/// default: one quiet bordered card, a hairline between rows, as Claude desktop draws a run of
/// SendMessage calls. The others are gallery versions kept beside it (MessageGroup.gallery.ts):
/// `guide`, the rows on the tree guide an edit group's rows hang from; `list`, the rows flush under
/// the line with hairlines and no border; `off`, no group at all, each message its own row as before
/// (the gallery's "before"). The native host sends no value, so the default holds there.
export type MessageGroupLook = "card" | "guide" | "list" | "off";

const LOOKS: readonly MessageGroupLook[] = ["card", "guide", "list", "off"];
let current: MessageGroupLook = "card";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureMessageGroupLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "card";
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
export const useMessageGroupLook = (): MessageGroupLook => useSyncExternalStore(subscribe, snapshot, snapshot);
