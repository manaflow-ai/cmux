// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); Claude and Codex support editing through completed turns. A chat's
// first prompt has no turn before it, and a failed or queued prompt was never answered.
import type { AcpmuxRow } from "../model";

const canEditThrough = (family: string | undefined) => family === "claude" || family === "codex";

const isEditablePrompt = (row: AcpmuxRow) =>
  row.kind === "user" && !!row.text && !row.failed && !row.queued && !row.pending && row.steer !== "waiting";

export function editableTurns(rows: readonly AcpmuxRow[], family: string | undefined): Map<string, number> {
  const seqs = new Map<string, number>();
  if (!canEditThrough(family)) return seqs;
  let through: number | undefined;
  for (const row of rows) {
    if (row.kind === "turnSummary" && row.seq !== undefined) through = row.seq;
    else if (through !== undefined && isEditablePrompt(row)) seqs.set(row.id, through);
  }
  return seqs;
}

/// `editableTurns` kept across snapshots, as `markRows` is: only the rows after the first that differs
/// from the previous snapshot's (by object) are read again, so a long chat's stream reads its last rows
/// alone. `seqs` is the previous snapshot's same Map while the editable prompts did not change, so a
/// caller can use it as a memo key.
export type EditableTurns = {
  rows: readonly AcpmuxRow[];
  family: string | undefined;
  /// Each turn summary with a seq (its row index and seq), to find the turn a resumed read is in.
  summaries: { index: number; seq: number }[];
  /// Each editable prompt (its row index, id and the turn its edit forks through).
  prompts: { index: number; id: string; seq: number }[];
  seqs: Map<string, number>;
};

export function trackEditableTurns(
  rows: readonly AcpmuxRow[],
  family: string | undefined,
  previous?: EditableTurns,
): EditableTurns {
  if (previous && previous.rows === rows && previous.family === family) return previous;
  let from = 0;
  if (previous && previous.family === family)
    while (from < rows.length && from < previous.rows.length && rows[from] === previous.rows[from]) from += 1;
  const before = <T extends { index: number }>(kept: readonly T[] | undefined) => {
    let keep = kept?.length ?? 0;
    while (keep > 0 && kept![keep - 1]!.index >= from) keep -= 1;
    return kept ? kept.slice(0, keep) : [];
  };
  const summaries = before(previous?.summaries);
  const prompts = canEditThrough(family) ? before(previous?.prompts) : [];
  let through: number | undefined = summaries.at(-1)?.seq;
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind === "turnSummary" && row.seq !== undefined) {
      summaries.push({ index, seq: row.seq });
      through = row.seq;
    } else if (canEditThrough(family) && through !== undefined && isEditablePrompt(row))
      prompts.push({ index, id: row.id, seq: through });
  }
  const same =
    previous &&
    previous.prompts.length === prompts.length &&
    previous.prompts.every((prompt, at) => prompt.id === prompts[at]!.id && prompt.seq === prompts[at]!.seq);
  const seqs = same ? previous.seqs : new Map(prompts.map((prompt) => [prompt.id, prompt.seq] as const));
  return { rows, family, summaries, prompts, seqs };
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
