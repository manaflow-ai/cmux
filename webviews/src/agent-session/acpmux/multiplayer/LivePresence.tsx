// The attached chat's presence, live, outside the pane's snapshot: a teammate opening the chat or
// typing redraws only the header faces and the typing line, never the transcript (the snapshot
// listener rebuilds the whole pane). The direct client sets it (direct.ts `presence`) with the chat
// it is for, and it draws only over that chat: during a switch the next chat attaches before the
// pane shows it. A snapshot's own `presence` (a gallery fixture) draws while no client has set one.
import { useSyncExternalStore } from "react";
import { PresenceStack, TypingLine } from "./Faces";
import type { ChatPresence } from "./participants";

type Shown = { sessionId: string | undefined; presence: ChatPresence | undefined };
let current: Shown | undefined;
const listeners = new Set<() => void>();

export const shownPresence = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  get: (): Shown | undefined => current,
  set(sessionId: string | undefined, presence: ChatPresence | undefined): void {
    if (current?.sessionId === sessionId && current?.presence === presence) return;
    current = presence === undefined && sessionId === undefined ? undefined : { sessionId, presence };
    for (const listener of listeners) listener();
  },
};

type Props = { sessionId?: string; fallback?: ChatPresence };

const useShown = ({ sessionId, fallback }: Props) => {
  const shown = useSyncExternalStore(shownPresence.subscribe, shownPresence.get, shownPresence.get);
  if (!shown) return fallback;
  return shown.sessionId === sessionId ? shown.presence : undefined;
};

/// Who else has the chat open, in the header.
export function LivePresenceStack(props: Props) {
  const presence = useShown(props);
  return presence ? <PresenceStack viewing={presence.viewing} /> : null;
}

/// Who else types, over the composer.
export function LiveTypingLine(props: Props) {
  const presence = useShown(props);
  return presence ? <TypingLine typing={presence.typing} /> : null;
}
