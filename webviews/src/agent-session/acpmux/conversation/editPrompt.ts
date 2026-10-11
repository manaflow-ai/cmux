// Edit and resend (cx-ncc.60): the prompts a chat can edit in place, each with the turn its edit forks
// through (the completed turn before it). acpmux forks a Claude chat through any completed turn
// (`hub/fork_at.rs`); other agents fork only at a chat's end, so none of their prompts edit.
import type { AcpmuxRow } from "../model";

export function editableTurns(rows: readonly AcpmuxRow[], family: string | undefined): Map<string, number> {
  void rows;
  void family;
  return new Map();
}
