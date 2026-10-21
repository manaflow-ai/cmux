// Each subagent's color, after Codex's phone app: a dot in the agents list (AgentsPill.tsx) and its
// name in the transcript (SubagentGroup.tsx) share it, so an agent reads as the same one anywhere.
// The color comes from the agent's id alone (a hash), so it holds as others start and end, across
// a reload, when older history loads and in the agent's own pane. Two agents can share a color;
// the name beside each tells them apart. subagents.css maps the tones to the theme's terminal colors.
import { createContext } from "react";
import type { Subagent } from "./subagentFold";

/// How many tones there are (subagents.css `[data-agent-tone]`).
export const AGENT_TONES = 5;

/// The tone of the subagent `id`: its FNV-1a hash, modulo the tones.
export function agentTone(id: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < id.length; index++) hash = Math.imul(hash ^ id.charCodeAt(index), 0x01000193);
  return (hash >>> 0) % AGENT_TONES;
}

/// The tone of each subagent in `agents`, by id.
export function agentTones(agents: Iterable<Subagent>): Map<string, number> {
  return new Map([...agents].map((agent) => [agent.id, agentTone(agent.id)]));
}

/// The shown chat's tones (App.tsx); undefined where none apply.
export const AgentTonesContext = createContext<ReadonlyMap<string, number> | undefined>(undefined);
