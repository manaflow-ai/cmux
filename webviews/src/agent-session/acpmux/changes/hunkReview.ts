// Hunk review in the changes view: the reader accepts or rejects each hunk of a turn, and the
// rejected ones go to the agent as one revert prompt.
import { hunkKey, hunkPatch, type DiffHunk, type TurnFile } from "../diff";

/// What the reader decided about a hunk: keep it, undo it, or undo already asked of the agent.
export type HunkDecision = "accepted" | "rejected" | "requested";
export type HunkReview = {
  decisions: ReadonlyMap<string, HunkDecision>;
  decide: (key: string, decision: HunkDecision | undefined) => void;
  requestRevert: (keys: string[], prompt: string) => void;
};
/// `label` names the hunk for its buttons, so a screen reader can tell one hunk's Reject from
/// another's.
export type HunkAnchor = { key: string; label: string };
/// The hunk whose action the reader just took; its next button takes focus, since the one
/// pressed is replaced.
export type FocusAfter = { current: string | undefined };

/// A hunk's actions sit under its last changed line, on the side that line is on.
export function hunkAnchor(hunk: DiffHunk, key: string, file: TurnFile, numbered: boolean) {
  const changed = hunk.lines.filter((line) => line.type !== "context");
  const last = changed[changed.length - 1];
  if (!last) return undefined;
  const first = changed[0]!;
  const line = first.newLine ?? first.oldLine;
  const label = numbered && line !== undefined ? `${file.displayPath} line ${line}` : file.displayPath;
  return last.type === "add"
    ? { side: "additions" as const, lineNumber: last.newLine!, metadata: { key, label } }
    : { side: "deletions" as const, lineNumber: last.oldLine!, metadata: { key, label } };
}

/// The rejected hunks not yet sent, each with its key and patch, in file order.
export function rejectedHunks(files: TurnFile[], decisions: ReadonlyMap<string, HunkDecision>) {
  return files.flatMap((file) =>
    file.edits.flatMap((edit, editIndex) =>
      edit.hunks.flatMap((hunk, hunkIndex) => {
        const key = hunkKey(file, editIndex, hunkIndex);
        return decisions.get(key) === "rejected" ? [{ key, patch: hunkPatch(file, edit, hunk) }] : [];
      }),
    ),
  );
}
