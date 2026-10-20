// acpmux's agent pair guard (cmux-tui/crates/acpmux/src/hub/agent_pairs.rs) pauses two agent
// chats that keep messaging each other without progress. Each chat's transcript gets mux records:
//   agent_pair_paused  {peer, peerName, reason: alternating|repeating, count, promptId, resume}
//   agent_pair_held    {from, fromName, to, promptId, text, provenance, prompt, ...}: a message
//                      to this chat held while paused (only the receiver's transcript)
//   agent_pair_resumed {peer, by: request|person, delivered}
// A pause is one row (AgentPairNote.tsx) that counts the messages held for it and collapses once
// the pair resumes. A held message is never a prompt row: it reaches the chat as a prompt only
// when acpmux delivers it after the resume.
import type { AcpmuxAgentPair, AcpmuxRow } from "../model";

export const AGENT_PAIR_ROW = "agentPair";
export const AGENT_PAIR_RESUME_METHOD = "_acpmux/agent_pair_resume";

type PairRecord = { seq: number; at: number; kind: string; msg: Record<string, unknown> };

const str = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);

/// The newest pause with `peer` that has not resumed.
function openPause(rows: ReadonlyMap<string, AcpmuxRow>, peer: string): AcpmuxRow | undefined {
  let found: AcpmuxRow | undefined;
  for (const row of rows.values())
    if (row.kind === AGENT_PAIR_ROW && row.agentPair?.peer === peer && !row.agentPair.resumed) found = row;
  return found;
}

function update(rows: Map<string, AcpmuxRow>, row: AcpmuxRow, pair: Partial<AcpmuxAgentPair>): void {
  rows.set(row.id, { ...row, version: row.version + 1, agentPair: { ...row.agentPair!, ...pair } });
}

/// Applies an agent pair record to `rows`; false for any other record (or a malformed one).
export function reduceAgentPair(rows: Map<string, AcpmuxRow>, event: PairRecord): boolean {
  const msg = event.msg ?? {};
  if (event.kind === "agent_pair_paused") {
    const peer = str(msg.peer);
    if (!peer) return true;
    const id = `agent-pair-${event.seq}`;
    rows.set(id, {
      id,
      version: 1,
      at: event.at,
      seq: event.seq,
      kind: AGENT_PAIR_ROW,
      agentPair: {
        peer,
        peerName: str(msg.peerName) ?? "",
        reason: msg.reason === "repeating" ? "repeating" : "alternating",
        count: typeof msg.count === "number" && Number.isFinite(msg.count) ? msg.count : 0,
        held: 0,
      },
    });
    return true;
  }
  if (event.kind === "agent_pair_held") {
    const from = str(msg.from);
    const row = from ? openPause(rows, from) : undefined;
    if (row) update(rows, row, { held: row.agentPair!.held + 1 });
    return true;
  }
  if (event.kind === "agent_pair_resumed") {
    const peer = str(msg.peer);
    const row = peer ? openPause(rows, peer) : undefined;
    if (row) update(rows, row, { resumed: true });
    return true;
  }
  return false;
}
