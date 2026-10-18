// The summary card's place per chat (summary/SummaryCard.tsx): shown or not, and folded to its
// header or open. This is the pane's own UI state, kept in localStorage by session id, so a chat
// comes back as the user left it, in this pane and in a pane opened on it later.
//
// A chat the user has not touched yet shows the card, open, once it has subagents: they are what
// the card follows while a turn runs. Any choice the user makes (show, hide, fold) is stored and
// wins from then on.
import { useCallback, useState, useSyncExternalStore } from "react";

export type SummaryCardState = { shown: boolean; collapsed: boolean };

const KEY = "cmux.acpmux.summaryCard";
/// Chats remembered; the oldest choice goes first.
const LIMIT = 200;

let choices: Map<string, SummaryCardState> | undefined;
const listeners = new Set<() => void>();

function load(): Map<string, SummaryCardState> {
  if (choices) return choices;
  choices = new Map();
  try {
    const value: unknown = JSON.parse(globalThis.localStorage?.getItem(KEY) ?? "null");
    if (value && typeof value === "object")
      for (const [id, state] of Object.entries(value as Record<string, unknown>)) {
        const raw = state as Partial<SummaryCardState> | null;
        if (raw && typeof raw.shown === "boolean" && typeof raw.collapsed === "boolean")
          choices.set(id, { shown: raw.shown, collapsed: raw.collapsed });
      }
  } catch {
    // An unreadable value is a chat with no choice yet.
  }
  return choices;
}

function save(sessionId: string, state: SummaryCardState) {
  const map = load();
  map.delete(sessionId);
  map.set(sessionId, state);
  while (map.size > LIMIT) map.delete(map.keys().next().value!);
  try {
    globalThis.localStorage?.setItem(KEY, JSON.stringify(Object.fromEntries(map)));
  } catch {
    // Storage may be full or absent (tests, private windows): the choice holds for this page.
  }
  for (const listener of listeners) listener();
}

/// Forgets every chat's choice: the gallery mounts each variant on a clean slate, as all its chats
/// share one session id.
export function resetSummaryCards() {
  choices = new Map();
  try {
    globalThis.localStorage?.removeItem(KEY);
  } catch {
    // Nothing stored.
  }
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

/// The card of chat `sessionId`. `hasSubagents` shows it for a chat with no stored choice. A pane
/// with no session id yet keeps its choice in memory until it has one.
export function useSummaryCard(sessionId: string | undefined, hasSubagents: boolean) {
  const stored = useSyncExternalStore(subscribe, () => (sessionId ? load().get(sessionId) : undefined));
  const [local, setLocal] = useState<SummaryCardState>();
  const state: SummaryCardState = (sessionId ? stored : local) ?? {
    shown: hasSubagents,
    collapsed: false,
  };
  const { shown, collapsed } = state;
  const set = useCallback(
    (next: SummaryCardState) => (sessionId ? save(sessionId, next) : setLocal(next)),
    [sessionId],
  );
  const toggle = useCallback(
    () => set({ shown: !shown, collapsed: shown ? collapsed : false }),
    [set, shown, collapsed],
  );
  const show = useCallback(() => set({ shown: true, collapsed: false }), [set]);
  const close = useCallback(() => set({ shown: false, collapsed }), [set, collapsed]);
  const fold = useCallback((next: boolean) => set({ shown: true, collapsed: next }), [set]);
  return { shown, column: true, reserve: false, collapsed, toggle, show, close, fold };
}

export type SummaryCardControl = ReturnType<typeof useSummaryCard>;
