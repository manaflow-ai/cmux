// Each subagent's color, after Codex's phone app: a dot in the agents list (AgentsPill.tsx) and its
// name in the transcript (SubagentGroup.tsx) share it, so an agent reads as the same one anywhere.
// An agent keeps its tone for the life of the chat: tones are handed out per chat, in the order
// agents start, and one given is never changed while the page lives, so an agent's color holds as
// others start and end. A new agent takes a tone no running agent has, so two agents running at
// once differ while a tone is free; among those, the one fewest agents ever had (the first on a
// tie). The map lives in the page, so a separate subagent pane, its own page, can color the same
// agent apart. subagents.css maps the tones to the theme's terminal colors.
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
  const all = [...agents];
  const runs = new Set(all.filter((agent) => agent.state === "running").map((agent) => agent.id));
  for (const agent of fresh) {
    // Ranked by running agents first, then by every agent ever given the tone.
    const live = Array.from({ length: AGENT_TONES }, () => 0);
    const ever = Array.from({ length: AGENT_TONES }, () => 0);
    for (const [id, tone] of tones) {
      ever[tone]! += 1;
      if (runs.has(id)) live[tone]! += 1;
    }
    const rank = (tone: number) => live[tone]! * (tones.size + 1) + ever[tone]!;
    let best = 0;
    for (let tone = 1; tone < AGENT_TONES; tone++) if (rank(tone) < rank(best)) best = tone;
    tones.set(agent.id, best);
  }
  return new Map(tones);
}

/// The shown chat's tones (App.tsx); undefined where none apply.
export const AgentTonesContext = createContext<ReadonlyMap<string, number> | undefined>(undefined);
