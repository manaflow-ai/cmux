// Each subagent's color, after Codex's phone app: a dot in the agents list (AgentsPill.tsx) and its
// name in the transcript (SubagentGroup.tsx) share it, so an agent reads as the same one anywhere.
// An agent keeps its tone for the life of the chat: tones are handed out per chat, in the order
// agents start, and one given is never taken back while the page lives, so an agent's color holds
// as others start and end. A new agent takes the tone fewest agents have (the first on a tie).
// subagents.css maps the tones to the theme's terminal colors.
import { createContext } from "react";
import type { Subagent } from "./subagentFold";

/// How many tones there are (subagents.css `[data-agent-tone]`).
export const AGENT_TONES = 5;

const chats = new Map<string, Map<string, number>>();

/// The tone of each of chat `chat`'s subagents `agents` (nested ones included), as a new map.
export function agentTones(chat: string, agents: Iterable<Subagent>): Map<string, number> {
  let tones = chats.get(chat);
  if (!tones) chats.set(chat, (tones = new Map()));
  const fresh = [...agents]
    .filter((agent) => !tones.has(agent.id))
    .sort((a, b) => a.startedAt - b.startedAt || a.id.localeCompare(b.id));
  for (const agent of fresh) {
    const used = Array.from({ length: AGENT_TONES }, () => 0);
    for (const tone of tones.values()) used[tone]! += 1;
    tones.set(agent.id, used.indexOf(Math.min(...used)));
  }
  return new Map(tones);
}

/// The shown chat's tones (App.tsx); undefined where none apply.
export const AgentTonesContext = createContext<ReadonlyMap<string, number> | undefined>(undefined);
