// Subagents in agent panes of their own, right of the chat (cx-1933q). The app opens them
// (`chat.subagentPane {subagent, focus}`, AgentSubagentPanes.swift): a tab on the chat's own
// session, in the chat's right pane, that opens on the
// subagent's view (a `revealTurn` of `subagent:<id>`). A refused request leaves the source
// transcript unchanged, so native tab identity and the displayed subagent stay consistent.
//
// A chat pane opens a pane by itself for each subagent its chat starts while the pane shows it,
// only once the user turned that on (the summary card's switch, kept in localStorage). It is off
// by default: agent work starts many subagents, and a split for each crowded the workspace. A
// click on a subagent still opens its pane. The subagents a chat already had when the pane first
// showed it open none: they are history.
import { useEffect, useRef, useSyncExternalStore } from "react";
import type { AcpmuxRow } from "../model";
import { subagentsIn } from "./subagentRows";
import { NativeError } from "../nativeError";

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
export type SubagentPaneResult = "opened" | "refused" | "error";

/// The host has no subagent panes at all: no app behind the page (the gallery, a browser), the dev
/// host (`native.unsupported`, dev-host/host.ts), or a pane whose host answers `unsupported` (a
/// floating chat, an older app). Those show it in place, as a refusal.
const NO_PANES = new Set(["native.not_connected", "native.unsupported", "unsupported"]);

/// Asks the app for subagent `id`'s pane. A native refusal is distinct from a lost transport reply:
/// only the former permits the in-place fallback.
export function openSubagentPane(call: Call, id: string, focus: boolean): Promise<SubagentPaneResult> {
  return nativePaneResult(call("chat.subagentPane", { subagent: id, focus }));
}

/// A native pane request's `{opened}` reply as a ``SubagentPaneResult``.
export async function nativePaneResult(reply: Promise<unknown>): Promise<SubagentPaneResult> {
  try {
    return ((await reply) as { opened?: unknown } | null)?.opened === true ? "opened" : "refused";
  } catch (error) {
    return error instanceof NativeError && error.code && NO_PANES.has(error.code) ? "refused" : "error";
  }
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
