// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); Claude and Codex support editing through completed turns. A chat's
// first prompt has no turn before it, and a failed or queued prompt was never answered.
//
// The prompt lifecycle (acpmux-core `chat/prompt_lifecycle.rs`, hq docs/design/user-message-lifecycle.md):
// Edit and resend shows only once the prompt's own turn has ended (`answered`). While the agent is
// still working on it (`read`) there is nothing to edit: it has been read, and a rewind would cut a
// turn that is still running (Leo, 2026-11-22: "why am i seeing the edit option available after
// you've already read it?"). A steer (`steer`, waiting or landed) never edits and resends: its turn
// opened with another prompt, which a fork through the turn before would drop.
import type { AcpmuxRow } from "../model";

// `family`: the chat's family, or acpmux's own answer (`forksAnyTurn`, messageMenu.ts) when it gave one.
const canEditThrough = (family: string | boolean | undefined) =>
  typeof family === "boolean" ? family : family === "claude" || family === "codex";

const isEditablePrompt = (row: AcpmuxRow) =>
  row.kind === "user" && !!row.text && !row.failed && !row.queued && !row.pending && row.steer === undefined;

export function editableTurns(rows: readonly AcpmuxRow[], family: string | boolean | undefined): Map<string, number> {
  return new Map(trackEditableTurns(rows, family).seqs);
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
  // A prompt edits only once a turn summary follows it (its turn ended), so the prompts after the
  // last kept summary are read again: the running turn's tail, never the whole chat.
  from = Math.min(from, (summaries.at(-1)?.index ?? -1) + 1);
  const prompts = canEditThrough(family) ? before(previous?.prompts) : [];
  let through: number | undefined = summaries.at(-1)?.seq;
  // Prompts since the last summary: they edit once a summary closes their turn.
  let open: { index: number; id: string; seq: number }[] = [];
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind === "turnSummary") {
      // Any summary ends the prompts' turn; only a logged one (with a seq) is a turn to fork through.
      prompts.push(...open);
      open = [];
      if (row.seq !== undefined) {
        summaries.push({ index, seq: row.seq });
        through = row.seq;
      }
    } else if (canEditThrough(family) && through !== undefined && isEditablePrompt(row))
      open.push({ index, id: row.id, seq: through });
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
/// Every prompt of a turn forks through it: the prompt that opened it and each steer read in it.
export function promptTurns(rows: readonly AcpmuxRow[]): Map<string, number> {
  return new Map(trackPromptTurns(rows).seqs);
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
  // The prompts still waiting for their turn's end where the read resumes: those after the last
  // answered turn's summary (a turn's opening prompt and the steers read in it).
  const answered = turns.at(-1)?.index ?? -1;
  // Read back from the end, so a resumed read costs the open turn's prompts, not the chat's.
  let first = users.length;
  while (first > 0 && users[first - 1]!.index > answered) first -= 1;
  let open = users.slice(first).map((user) => user.id);
  for (let index = from; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind === "user" && !row.failed && !row.queued && !row.pending) {
      users.push({ index, id: row.id });
      open.push(row.id);
    } else if (row.kind === "turnSummary" && row.seq !== undefined && open.length > 0) {
      for (const id of open) turns.push({ index, id, seq: row.seq });
      open = [];
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
