// acpmux's agent pair guard (cmux-tui/crates/acpmux/src/hub/agent_pairs.rs) pauses two agent
// chats that keep messaging each other without progress. Each chat's transcript gets mux records:
//   agent_pair_paused   {peer, peerName, reason, count, windowSecs, promptId, error, resume}:
//                       reason alternating, repeating, cap (more than `count` within
//                       `windowSecs`) or release_failed (a held message failed after a resume;
//                       with `error`, without `count`); in both chats
//   agent_pair_held     {from, fromName, to, promptId, text, ...}: a message to this chat held
//                       while paused (only the receiver's transcript); a resend logs it again
//   agent_pair_resumed  {peer, by: request|person, delivered}: in both chats
//   agent_pair_released {promptId, peer}: a held message delivered (the receiver's)
//   agent_pair_dropped  {promptId, peer, error}: one acpmux gave up on (both chats)
// A pause is one row (AgentPairNote.tsx). It keeps the messages still held, once each by prompt
// id, counts the released and dropped ones, and collapses once the pair resumes. A re-pause with
// the same peer is a row of its own that takes over what the row before it still held, so a
// reload, which replays the same records, draws the same rows. A held message is never a prompt
// row: it reaches the chat as a prompt only when acpmux delivers it.
import type { AcpmuxAgentPair, AcpmuxRow } from "../model";

export const AGENT_PAIR_ROW = "agentPair";

type PairRecord = { seq: number; at: number; kind: string; msg: Record<string, unknown> };
type Reason = AcpmuxAgentPair["reason"];

const REASONS: readonly Reason[] = ["alternating", "repeating", "cap", "release_failed"];
const str = (value: unknown): string | undefined => (typeof value === "string" && value ? value : undefined);
const num = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/// The newest pause with `peer`, resumed or not.
function newest(rows: ReadonlyMap<string, AcpmuxRow>, peer: string): AcpmuxRow | undefined {
  let found: AcpmuxRow | undefined;
  for (const row of rows.values()) if (row.kind === AGENT_PAIR_ROW && row.agentPair?.peer === peer) found = row;
  return found;
}

function update(rows: Map<string, AcpmuxRow>, row: AcpmuxRow, pair: Partial<AcpmuxAgentPair>): void {
  rows.set(row.id, { ...row, version: row.version + 1, agentPair: { ...row.agentPair!, ...pair } });
}

/// The pause's own fields from its record.
function pauseOf(msg: Record<string, unknown>, peer: string) {
  const reason = REASONS.find((r) => r === msg.reason) ?? "alternating";
  const windowSecs = num(msg.windowSecs);
  const error = str(msg.error);
  return {
    peer,
    peerName: str(msg.peerName) ?? "",
    reason,
    count: num(msg.count) ?? 0,
    ...(windowSecs !== undefined ? { windowSecs } : {}),
    ...(error ? { error } : {}),
  };
}

/// The newest row with `peer` that still holds `promptId`.
function holding(rows: ReadonlyMap<string, AcpmuxRow>, peer: string, promptId: string | undefined) {
  let found: AcpmuxRow | undefined;
  for (const row of rows.values())
    if (
      row.kind === AGENT_PAIR_ROW &&
      row.agentPair?.peer === peer &&
      row.agentPair.held.some((item) => item.promptId === promptId)
    )
      found = row;
  return found;
}

/// A released or dropped message: off the row that holds it, counted on it (or, when this chat
/// never held it, as the other chat's records say, on the newest row with that peer).
function settle(rows: Map<string, AcpmuxRow>, peer: string, promptId: string | undefined, how: "released" | "dropped") {
  const row = holding(rows, peer, promptId) ?? newest(rows, peer);
  if (!row) return;
  const pair = row.agentPair!;
  update(rows, row, {
    held: pair.held.filter((item) => item.promptId !== promptId),
    [how]: pair[how] + 1,
  });
}

/// Applies an agent pair record to `rows`; false for any other record (or a malformed one).
export function reduceAgentPair(rows: Map<string, AcpmuxRow>, event: PairRecord): boolean {
  const msg = event.msg ?? {};
  switch (event.kind) {
    case "agent_pair_paused": {
      const peer = str(msg.peer);
      if (!peer) return true;
      const before = newest(rows, peer);
      // Paused again before it resumed: the same row, with the newer reason.
      if (before && !before.agentPair!.resumed) {
        const { error: _error, windowSecs: _window, ...kept } = before.agentPair!;
        rows.set(before.id, {
          ...before,
          version: before.version + 1,
          agentPair: { ...kept, ...pauseOf(msg, peer) },
        });
        return true;
      }
      const id = `agent-pair-${event.seq}`;
      // What the pause before still held moves to this one.
      const carried = before?.agentPair!.held ?? [];
      if (before && carried.length) update(rows, before, { held: [] });
      rows.set(id, {
        id,
        version: 1,
        at: event.at,
        seq: event.seq,
        kind: AGENT_PAIR_ROW,
        agentPair: { ...pauseOf(msg, peer), held: carried, released: 0, dropped: 0 },
      });
      return true;
    }
    case "agent_pair_held": {
      const from = str(msg.from);
      const promptId = str(msg.promptId);
      const row = from ? newest(rows, from) : undefined;
      // A resend logs the same message again.
      if (!from || !row || !promptId || holding(rows, from, promptId)) return true;
      update(rows, row, { held: [...row.agentPair!.held, { promptId, text: str(msg.text) ?? "" }] });
      return true;
    }
    case "agent_pair_resumed": {
      const peer = str(msg.peer);
      const row = peer ? newest(rows, peer) : undefined;
      if (row && !row.agentPair!.resumed) update(rows, row, { resumed: true });
      return true;
    }
    case "agent_pair_released":
    case "agent_pair_dropped": {
      const peer = str(msg.peer);
      if (peer) settle(rows, peer, str(msg.promptId), event.kind === "agent_pair_released" ? "released" : "dropped");
      return true;
    }
    default:
      return false;
  }
}
