// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); Claude and Codex support editing through completed turns. A chat's
// first prompt has no turn before it, and a failed or queued prompt was never answered.
import type { AcpmuxRow } from "../model";

export function editableTurns(rows: readonly AcpmuxRow[], family: string | undefined): Map<string, number> {
  const seqs = new Map<string, number>();
  if (family !== "claude" && family !== "codex") return seqs;
  let through: number | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary" && row.seq !== undefined) through = row.seq;
    else if (
      row.kind === "user" &&
      through !== undefined &&
      row.text &&
      !row.failed &&
      !row.queued &&
      !row.pending &&
      row.steer !== "waiting"
    )
      seqs.set(row.id, through);
  }
  return seqs;
}

/// Each answered prompt's own turn (its turn summary's seq), the turn a prompt's Fork goes through,
/// as its right-click Fork does (messageMenu.ts): the new chat keeps the prompt and its answer.
export function promptTurns(rows: readonly AcpmuxRow[]): Map<string, number> {
  const seqs = new Map<string, number>();
  let prompt: string | undefined;
  for (const row of rows) {
    if (row.kind === "user" && !row.failed && !row.queued && !row.pending) prompt = row.id;
    else if (row.kind === "turnSummary" && row.seq !== undefined && prompt !== undefined) {
      seqs.set(prompt, row.seq);
      prompt = undefined;
    }
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
