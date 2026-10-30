// Show more lines (cx-ncc.85): a git scope's file read again with every unchanged line as context
// (`git.diff` with `paths` and `context_lines`), so its diff knows the whole file and Pierre's hunk
// separators expand. The read gives both versions of the file; the shown hunks stay the scope's.
import type { DiffEdit, DiffLine } from "../diff";
import { patchHunks } from "./model";

/// More unchanged lines than any file has: the session host's ceiling for `context_lines`.
export const WHOLE_FILE_CONTEXT = 1_000_000;

/// Both versions of a file, as Pierre takes them.
export type WholeFile = { before: string; after: string };

const changes = (lines: readonly DiffLine[]) =>
  lines
    .filter((line) => line.type !== "context")
    .map((line) => `${line.type}:${line.oldLine}:${line.newLine}:${line.text}`);

/// Both versions of the file `path` (repository-relative) from a whole-file `git.diff` answer, or
/// undefined when the answer cannot stand for the shown diff: no such file, a cut patch, more than
/// one hunk, a hunk not from the first line, or changes other than `edit`'s (the file changed since
/// the scope loaded).
export function readWholeFile(value: unknown, path: string, edit: DiffEdit): WholeFile | undefined {
  const files = (value as { files?: unknown } | null)?.files;
  if (!Array.isArray(files)) return undefined;
  const file = files.find((entry) => (entry as { path?: unknown } | null)?.path === path) as
    | { patch?: unknown; patch_truncated?: unknown; binary?: unknown }
    | undefined;
  if (!file || typeof file.patch !== "string" || file.patch_truncated === true || file.binary === true)
    return undefined;
  const hunks = patchHunks(file.patch);
  const whole = hunks[0];
  if (hunks.length !== 1 || !whole) return undefined;
  // A host that ignored or capped `context_lines` answers with the hunk's own context: not the file.
  const first = (side: "oldLine" | "newLine") => whole.lines.find((line) => line[side] !== undefined)?.[side];
  if (first("oldLine") !== 1 || first("newLine") !== 1) return undefined;
  const shown = changes(edit.hunks.flatMap((hunk) => hunk.lines));
  const read = changes(whole.lines);
  if (shown.length !== read.length || shown.some((line, index) => line !== read[index])) return undefined;
  const version = (skip: DiffLine["type"]) =>
    whole.lines
      .filter((line) => line.type !== skip)
      .map((line) => `${line.text}\n`)
      .join("");
  return { before: version("add"), after: version("del") };
}
