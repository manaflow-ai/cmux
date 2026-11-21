// Each subagent's color, after Codex's phone app: a dot in the agents list (AgentsPill.tsx) and its
// name and mark in the transcript (SubagentGroup.tsx), the tray and Session Info share it, so an
// agent reads as the same one anywhere.
//
// Leo, 2026-11-04: "Each subagent gets its own colour (medium). Today three Claude subagents look
// identical. Keep the harness mark and add a stable colour per subagent, used everywhere it shows."
// A tone from the id's hash alone gives three agents a shared colour about half the time (five
// tones), so the shown chat assigns its agents' tones together (`agentTones`): in start order each
// takes its hash's tone, or the next one none of its siblings holds, so up to `AGENT_TONES` agents
// in a chat never share one. While the chat has no more agents than tones, an agent keeps the tone
// it was given while the page lives (a new agent, a finished one, older history loading later never
// recolor it); past that, or for two agents first colored in separate lists, a later one can move.
// The same chat's full list gets the same tones after a reload. `agentTone(id)` reads that assignment,
// so every surface that draws the agent draws its tone; an id no chat assigned (a gallery, a test)
// falls back to its hash. subagents.css maps the tones to the theme's terminal colors.
import { createContext } from "react";

/// How many tones there are (subagents.css `[data-agent-tone]`).
export const AGENT_TONES = 5;

/// The tone of `id` from its FNV-1a hash, modulo the tones: where its chat's assignment starts.
export function hashTone(id: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < id.length; index++) hash = Math.imul(hash ^ id.charCodeAt(index), 0x01000193);
  return (hash >>> 0) % AGENT_TONES;
}

/// Tones a chat assigned, by agent id. Bounded: the oldest assignment is dropped first.
const assigned = new Map<string, number>();
const ASSIGNED_LIMIT = 4096;

/// The tone of the agent `id`: the one its chat assigned (`agentTones`), else its hash's.
export function agentTone(id: string): number {
  return assigned.get(id) ?? hashTone(id);
}

/// What `agentTones` reads of an agent: its id and when it started (a sub-session's `createdAt`).
export type TonedAgent = { id: string; startedAt?: number };

/// The tones of a chat's agents (its subagents and the chats it started), by id: distinct while there
/// are no more agents than tones, and as even as they can be past that. An agent keeps the tone it
/// already has; a newer one moves off a tone a sibling holds.
export function agentTones(agents: Iterable<TonedAgent>): Map<string, number> {
  const byStart = [...agents].sort(
    (a, b) => (a.startedAt ?? Infinity) - (b.startedAt ?? Infinity) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );
  // Agents this page already colored go first, so one found later (older history) never takes
  // their tone; the rest follow in start order.
  const ordered = [...byStart.filter(({ id }) => assigned.has(id)), ...byStart.filter(({ id }) => !assigned.has(id))];
  const uses = Array.from({ length: AGENT_TONES }, () => 0);
  const tones = new Map<string, number>();
  for (const { id } of ordered) {
    if (tones.has(id)) continue;
    const kept = assigned.get(id);
    const least = Math.min(...uses);
    let tone = kept !== undefined && uses[kept] === least ? kept : undefined;
    if (tone === undefined) {
      const start = hashTone(id);
      for (let step = 0; step < AGENT_TONES; step++) {
        const candidate = (start + step) % AGENT_TONES;
        if (uses[candidate] === least) {
          tone = candidate;
          break;
        }
      }
    }
    tone ??= hashTone(id);
    uses[tone]++;
    tones.set(id, tone);
    if (kept !== tone) {
      assigned.delete(id);
      assigned.set(id, tone);
      if (assigned.size > ASSIGNED_LIMIT) assigned.delete(assigned.keys().next().value!);
    }
  }
  return tones;
}

/// Forget every assignment (tests).
export function resetAgentTones(): void {
  assigned.clear();
}

/// The shown chat's tones (App.tsx); undefined where none apply.
export const AgentTonesContext = createContext<ReadonlyMap<string, number> | undefined>(undefined);
