// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); other agents fork only at a chat's end, so none of their prompts edit. A chat's
// first prompt has no turn before it, and a failed or queued prompt was never answered.
import type { AcpmuxRow } from "../model";

export function editableTurns(rows: readonly AcpmuxRow[], family: string | undefined): Map<string, number> {
  const seqs = new Map<string, number>();
  if (family !== "claude") return seqs;
  let through: number | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary" && row.seq !== undefined) through = row.seq;
    else if (
      row.kind === "user" &&
      through !== undefined &&
      row.text &&
      !row.message &&
      !row.failed &&
      !row.queued &&
      !row.pending
    )
      seqs.set(row.id, through);
  }
  return seqs;
}

/// The same prompts as a string, so the App rebuilds its actions only when they change (not on every
/// streamed row).
export const editableKey = (seqs: ReadonlyMap<string, number>) =>
  [...seqs].map(([id, seq]) => `${id}:${seq}`).join(",");

/// The prompts back from `editableKey`.
export function editableSeqs(key: string): Map<string, number> {
  const seqs = new Map<string, number>();
  for (const entry of key ? key.split(",") : []) {
    const at = entry.lastIndexOf(":");
    seqs.set(entry.slice(0, at), Number(entry.slice(at + 1)));
  }
  return seqs;
}
