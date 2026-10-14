// Subagents beside the chat (cx-1933q). The app opens them (`chat.subagentPane {subagent, focus,
// tile, title}`, AgentSubagentPanes.swift, SubagentBeside.swift): a tab on the chat's own session
// that opens on the subagent's view (a `revealTurn` of `subagent:<id>`), named for its task. A
// row's click opens it as a tab in the pane right of the chat; Tile subagents (the card's button,
// the palette's action, a `revealTurn` of `subagents:tile`) opens each running one in a pane of
// its own, stacked right of the chat. A host that opens none (the gallery, the floating chat, an
// older app) shows the subagent in this pane instead.
//
// With "Tile subagents automatically" on (the summary card's switch and a Settings row, both
// `agentPane.tileSubagentsAutomatically` in cmux.json via composerSettings.ts; off unless turned
// on), a chat pane tiles each subagent its chat starts while the pane shows it. The
// subagents a chat already had when the pane first showed it open none: they are history.
import { useEffect, useRef } from "react";
import { showComposerControl, useComposerSettings } from "../composerSettings";
import type { AcpmuxRow } from "../model";
import type { Subagent } from "./subagentFold";
import { subagentsIn } from "./subagentRows";

/// The `revealTurn` prefix that opens a pane on a subagent's view.
export const SUBAGENT_REVEAL = "subagent:";

/// The `revealTurn` value that asks this chat's page to tile its running subagents.
export const SUBAGENTS_TILE = "subagents:tile";

/// The subagent a reveal names, or undefined for a turn.
export const revealedSubagent = (value: string) =>
  value.startsWith(SUBAGENT_REVEAL) ? value.slice(SUBAGENT_REVEAL.length) || undefined : undefined;

/// A subagent that started this long before the pane showed its chat still counts as new: the
/// snapshot that names it can trail its start.
const HISTORY_SLACK_MS = 3_000;
const setAutoOpen = (on: boolean) => showComposerControl("tileSubagentsAutomatically", on);

// The old switch's own copy, before the setting (#20694): drop it.
try {
  globalThis.localStorage?.removeItem("cmux.acpmux.subagentPanes");
} catch {
  // No storage.
}

/// Whether new subagents tile in panes of their own (off unless turned on).
export function useAutoOpenSubagents(): [boolean, (on: boolean) => void] {
  return [useComposerSettings().tileSubagentsAutomatically, setAutoOpen];
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// How the app opens a subagent: `tile` in a pane of its own, else a tab beside the chat; `title`
/// names its tab.
export type SubagentOpen = { focus: boolean; tile?: boolean; title?: string };

/// A subagent's tab title: its task's first line, else its name.
export const subagentTitle = (agent: Pick<Subagent, "task" | "name">) =>
  agent.task?.split("\n", 1)[0]?.trim() || agent.name;

/// Subagent `id`'s tab title, when the rows know it.
export function subagentTitleOf(
  id: string,
  rows: readonly AcpmuxRow[] = [],
  views?: Record<string, AcpmuxRow[]>,
): string | undefined {
  const agent = subagentsIn(rows, views).get(id);
  return agent && subagentTitle(agent);
}

/// Asks the app for subagent `id`'s tab or pane; false when it opened none.
export async function openSubagentPane(call: Call, id: string, how: SubagentOpen): Promise<boolean> {
  try {
    const reply = await call("chat.subagentPane", { subagent: id, ...how });
    return (reply as { opened?: unknown } | null)?.opened === true;
  } catch {
    return false;
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
    // While off nothing counts as handled: the setting reaches the page after its first rows, and
    // turning it on tiles the chat's new subagents still running.
    if (!enabled) return;
    for (const agent of subagentsIn(rows, views).values()) {
      if (chat.known.has(agent.id)) continue;
      chat.known.add(agent.id);
      if (agent.parent === null && agent.state === "running" && agent.startedAt + clockOffset >= chat.since)
        open(agent.id);
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `open` changes each render; rows drive it
  }, [sessionId, rows, views, enabled, clockOffset]);
}

/// The chat's own subagents still running, oldest first: what Tile subagents opens.
export const runningSubagents = (rows: readonly AcpmuxRow[], views: Record<string, AcpmuxRow[]> | undefined) =>
  [...subagentsIn(rows, views).values()]
    .filter((agent) => agent.parent === null && agent.state === "running")
    .sort((a, b) => a.startedAt - b.startedAt);

/// Tiles every running subagent of the chat in a pane of its own (the app stacks them right of the
/// chat and keeps them equal); returns how many it asked for.
export function tileSubagents(
  call: Call,
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> | undefined,
): number {
  const agents = runningSubagents(rows, views);
  for (const agent of agents)
    void openSubagentPane(call, agent.id, { focus: false, tile: true, title: subagentTitle(agent) });
  return agents.length;
}
