// Subagents in agent panes of their own, right of the chat (cx-1933q). The app opens them
// (`chat.subagentPane {subagent, focus}`, AgentSubagentPanes.swift): a tab on the chat's own
// session, in a new split right of the chat or below the newest subagent pane, that opens on the
// subagent's view (a `revealTurn` of `subagent:<id>`). A host that opens none (the gallery, the
// floating chat, an older app) shows the subagent in this pane instead.
//
// Subagents open in panes only once the user turned that on (the summary card's switch, kept in
// localStorage). It is off by default: agent work starts many subagents, and a split for each
// crowded the workspace. While it is off, a click on a subagent (a group line, a card row, the
// agents pill) shows it in the chat's own pane. While it is on, a click opens its pane, and a chat
// pane opens one by itself for each subagent its chat starts while the pane shows it. The
// subagents a chat already had when the pane first showed it open none: they are history.
import { useEffect, useRef, useSyncExternalStore } from "react";
import type { AcpmuxRow } from "../model";
import { subagentsIn } from "./subagentRows";

/// The `revealTurn` prefix that opens a pane on a subagent's view.
export const SUBAGENT_REVEAL = "subagent:";

/// The subagent a reveal names, or undefined for a turn.
export const revealedSubagent = (value: string) =>
  value.startsWith(SUBAGENT_REVEAL) ? value.slice(SUBAGENT_REVEAL.length) || undefined : undefined;

const KEY = "cmux.acpmux.subagentPanes";
/// A subagent that started this long before the pane showed its chat still counts as new: the
/// snapshot that names it can trail its start.
const HISTORY_SLACK_MS = 3_000;
const listeners = new Set<() => void>();
const read = () => {
  try {
    return globalThis.localStorage?.getItem(KEY) === "on";
  } catch {
    return false;
  }
};

const setAutoOpen = (next: boolean) => {
  try {
    if (next) globalThis.localStorage?.setItem(KEY, "on");
    else globalThis.localStorage?.removeItem(KEY);
  } catch {
    // No storage: the choice holds until the page reloads.
  }
  for (const listener of listeners) listener();
};

/// Whether new subagents open in panes of their own (off unless turned on).
export function useAutoOpenSubagents(): [boolean, (on: boolean) => void] {
  const on = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    read,
    read,
  );
  return [on, setAutoOpen];
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Asks the app for subagent `id`'s pane; false when it opened none.
export async function openSubagentPane(call: Call, id: string, focus: boolean): Promise<boolean> {
  try {
    const reply = await call("chat.subagentPane", { subagent: id, focus });
    return (reply as { opened?: unknown } | null)?.opened === true;
  } catch {
    return false;
  }
}

/// Shows subagent `id`: in a pane of its own (focused with `focus`) only while `panes` (the switch)
/// is on and this is the chat's pane (`inSubagentPane` false), else in this pane (`here`) when the
/// person asked (`focus`; a subagent's pane always shows it). A host that opens no pane shows it
/// here too when the person asked. Settles once it has shown it.
export async function showSubagent(
  call: Call,
  id: string,
  focus: boolean,
  options: { panes: boolean; inSubagentPane: boolean; here: (id: string) => void },
): Promise<void> {
  if (options.inSubagentPane || !options.panes) {
    if (focus || options.inSubagentPane) options.here(id);
    return;
  }
  const opened = await openSubagentPane(call, id, focus);
  if (!opened && focus) options.here(id);
}

/// Opens a pane for each subagent the chat `sessionId` starts from now on (its own, not nested
/// ones), while `enabled`.
export function useOpenNewSubagents(
  sessionId: string | undefined,
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> | undefined,
  enabled: boolean,
  open: (id: string) => void,
  /// The snapshot's `clockOffsetMs`: this computer's clock minus the session's.
  clockOffset = 0,
) {
  // Per chat: when this pane first showed it, and the subagents already handled. A subagent that
  // started before that is history (its rows can come after the first snapshot).
  const seen = useRef(new Map<string, { since: number; known: Set<string> }>());
  useEffect(() => {
    if (!sessionId) return;
    let chat = seen.current.get(sessionId);
    if (!chat) seen.current.set(sessionId, (chat = { since: Date.now() - HISTORY_SLACK_MS, known: new Set() }));
    for (const agent of subagentsIn(rows, views).values()) {
      if (chat.known.has(agent.id)) continue;
      chat.known.add(agent.id);
      if (enabled && agent.parent === null && agent.state === "running" && agent.startedAt + clockOffset >= chat.since)
        open(agent.id);
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `open` changes each render; rows drive it
  }, [sessionId, rows, views, enabled, clockOffset]);
}
