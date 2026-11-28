// Hunk review in the changes view: the reader accepts or rejects each hunk of a turn, and the
// rejected ones go to the agent as one revert prompt.
import { hunkKey, hunkPatch, type TurnFile } from "../diff";

/// What the reader decided about a hunk: keep it, undo it, or undo already asked of the agent.
export type HunkDecision = "accepted" | "rejected" | "requested";
export type HunkReview = {
  decisions: ReadonlyMap<string, HunkDecision>;
  decide: (key: string, decision: HunkDecision | undefined) => void;
  requestRevert: (keys: string[], prompt: string) => void;
};
/// `label` names the hunk for its buttons, so a screen reader can tell one hunk's Reject from
/// another's.
export type HunkAnchor = { key: string; label: string; keys: readonly string[] };
/// The hunk whose action the reader just took; its next button takes focus, since the one
/// pressed is replaced.
export type FocusAfter = { current: string | undefined };

/// Every review key in a turn's files, each with its original patch, in file order.
export function turnHunks(files: TurnFile[]) {
  return files.flatMap((file) =>
    file.edits.flatMap((edit, editIndex) =>
      edit.hunks.flatMap((hunk, hunkIndex) => {
        const key = hunkKey(file, editIndex, hunkIndex);
        return (hunk.reviewKeys ?? [key]).map((reviewKey) => ({ key: reviewKey, patch: hunkPatch(file, edit, hunk) }));
      }),
    ),
  );
}

/// Restore decisions that were marked requested when a revert request failed.
export function restoredDecisions(
  current: ReadonlyMap<string, HunkDecision>,
  previous: readonly (readonly [string, HunkDecision | undefined])[],
): Map<string, HunkDecision> {
  const next = new Map(current);
  for (const [key, decision] of previous) {
    if (next.get(key) !== "requested") continue;
    if (decision) next.set(key, decision);
    else next.delete(key);
  }
  return next;
}
