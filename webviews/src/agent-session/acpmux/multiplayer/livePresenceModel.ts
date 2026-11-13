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
