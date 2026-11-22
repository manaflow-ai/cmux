// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); Claude and Codex support editing through completed turns. A chat's
// first prompt has no turn before it, and a failed or queued prompt was never answered.
import type { AcpmuxRow } from "../model";

// `family`: the chat's family, or acpmux's own answer (`forksAnyTurn`, messageMenu.ts) when it gave one.
const canEditThrough = (family: string | boolean | undefined) =>
  typeof family === "boolean" ? family : family === "claude" || family === "codex";

const isEditablePrompt = (row: AcpmuxRow) =>
  row.kind === "user" && !!row.text && !row.failed && !row.queued && !row.pending && row.steer !== "waiting";

export function editableTurns(rows: readonly AcpmuxRow[], family: string | boolean | undefined): Map<string, number> {
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
  family: string | boolean | undefined;
  /// Each turn summary with a seq (its row index and seq), to find the turn a resumed read is in.
  summaries: { index: number; seq: number }[];
  /// Each editable prompt (its row index, id and the turn its edit forks through).
  prompts: { index: number; id: string; seq: number }[];
  seqs: Map<string, number>;
};

export function trackEditableTurns(
  rows: readonly AcpmuxRow[],
  family: string | boolean | undefined,
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

/// `promptTurns` kept across snapshots, as `trackEditableTurns` is: only the rows after the first that
/// differs from the previous snapshot's (by object) are read again, so a reply streaming under a long
/// chat reads its last rows alone, never the whole transcript on each render. `seqs` is the previous
/// snapshot's same Map while the answered prompts did not change, so a caller can use it as a memo key.
export type PromptTurns = {
  rows: readonly AcpmuxRow[];
  /// Each row that can be a turn's prompt (its row index and id).
  users: { index: number; id: string }[];
  /// Each answered prompt: its id, its turn's seq, and the row index of that turn's summary.
  turns: { index: number; id: string; seq: number }[];
  seqs: Map<string, number>;
};

const NO_PROMPT_TURNS: PromptTurns = { rows: [], users: [], turns: [], seqs: new Map() };

export function trackPromptTurns(rows: readonly AcpmuxRow[], previous?: PromptTurns): PromptTurns {
  if (previous && previous.rows === rows) return previous;
  if (rows.length === 0) return previous && previous.seqs.size === 0 ? previous : NO_PROMPT_TURNS;
  let from = 0;
  if (previous)
    while (from < rows.length && from < previous.rows.length && rows[from] === previous.rows[from]) from += 1;
  const before = <T extends { index: number }>(kept: readonly T[] | undefined) => {
    let keep = kept?.length ?? 0;
    while (keep > 0 && kept![keep - 1]!.index >= from) keep -= 1;
    return kept ? kept.slice(0, keep) : [];
  };
  const users = before(previous?.users);
  const turns = before(previous?.turns);
  // The prompt still waiting for its turn's end where the read resumes: the last one after the last
  // answered turn's summary.
  const waiting = users.at(-1);
  let prompt = waiting && waiting.index > (turns.at(-1)?.index ?? -1) ? waiting.id : undefined;
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind === "user" && !row.failed && !row.queued && !row.pending) {
      users.push({ index, id: row.id });
      prompt = row.id;
    } else if (row.kind === "turnSummary" && row.seq !== undefined && prompt !== undefined) {
      turns.push({ index, id: prompt, seq: row.seq });
      prompt = undefined;
    }
  }
  const same =
    previous &&
    previous.turns.length === turns.length &&
    previous.turns.every((turn, at) => turn.id === turns[at]!.id && turn.seq === turns[at]!.seq);
  // As `promptTurns`: a prompt id answered twice keeps its last turn.
  const seqs = same ? previous.seqs : new Map(turns.map((turn) => [turn.id, turn.seq] as const));
  return { rows, users, turns, seqs };
}

/// The same prompts as a string, so the App rebuilds its actions only when they change (not on every
/// streamed row).
export const editableKey = (seqs: ReadonlyMap<string, number>) =>
  [...seqs].map(([id, seq]) => `${id}:${seq}`).join(",");
