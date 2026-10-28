// Who a message to another agent went to, as a name a person reads (Leo 2026-10-21: the card's
// "→ a39e817af38ddf5e7" was a raw id). Claude Code's SendMessage names a subagent by the agentId
// its Agent call answered with; the chat's subagents (subagents/subagentFold.ts) carry that id
// with the Agent call's description, so the row shows the description. A name the call gives
// (a teammate's, an acpmux session's) shows as it is; an id nothing names (its Agent call is not
// in the loaded transcript) reads as a short id. The full id is the chip's tooltip
// (MessageCard.tsx), so it is still there to copy or match against a log.
import { createContext } from "react";
import type { Subagent } from "../subagents/subagentFold";

/// Each subagent's agentId to the name its row shows, for the chat the pane draws (App.tsx).
export const AgentNamesContext = createContext<ReadonlyMap<string, string>>(new Map());

/// The names of the chat's subagents by agentId: the Agent call's description, else its name.
export function agentNames(agents: readonly Subagent[]): ReadonlyMap<string, string> {
  const names = new Map<string, string>();
  for (const agent of agents) {
    const name = agent.task ?? agent.name;
    if (agent.agentId && name && !looksLikeId(name)) names.set(agent.agentId, name);
  }
  return names;
}

/// An opaque id rather than a name: Claude Code's agentIds (`a39e817af38ddf5e7`), hex digests, UUIDs.
export function looksLikeId(value: string): boolean {
  const text = value.trim();
  return (
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text) ||
    (/^[a-z]?[0-9a-f]{12,}$/i.test(text) && /\d/.test(text))
  );
}

/// The recipient as the row shows it: the subagent's description for its agentId, the name the
/// call gave, or undefined for an id nothing names (the caller shows ``shortId``).
export function recipientName(to: string | undefined, names: ReadonlyMap<string, string>): string | undefined {
  if (!to) return undefined;
  const named = names.get(to);
  if (named) return named;
  return looksLikeId(to) ? undefined : to;
}

/// An id nothing names, cut to its first characters (`a39e817af38ddf5e7` reads `a39e817a`): enough
/// to tell two subagents apart in one chat, short enough to read as a chip.
export function shortId(id: string): string {
  const text = id.trim();
  return text.length > SHORT_ID ? text.slice(0, SHORT_ID) : text;
}
const SHORT_ID = 8;
