// Copy git apply command: one POSIX shell command that applies a git scope's changes to another
// checkout, `git apply` reading the files' patches from a here-document. Paths are relative to
// the repository's top level, so it runs there wherever it is pasted. File modes are not in the
// scope: a new file applies as a regular one, and a mode change alone is not reproduced.
import type { ChangedFile, ChangeSet } from "./model";

const MARKER = "CMUX_PATCH";

function filePatch(file: ChangedFile): string {
  const from = file.previousPath ?? file.path;
  const added = file.status === "added" || file.status === "untracked";
  const deleted = file.status === "deleted";
  const lines = [`diff --git a/${from} b/${file.path}`];
  // git reads a created or deleted file from its mode line; the scope does not carry modes, so
  // a new file applies as a regular one.
  if (added) lines.push("new file mode 100644");
  if (deleted) lines.push("deleted file mode 100644");
  if (file.previousPath) lines.push(`rename from ${file.previousPath}`, `rename to ${file.path}`);
  const patch = file.patch ?? "";
  // A rename without hunks has no ---/+++ lines.
  if (patch !== "")
    lines.push(added ? "--- /dev/null" : `--- a/${from}`, deleted ? "+++ /dev/null" : `+++ b/${file.path}`);
  return `${lines.join("\n")}\n${patch === "" || patch.endsWith("\n") ? patch : `${patch}\n`}`;
}

/// git writes a path with a control character, a quote or a backslash in C quotes.
const QUOTED = /["\\\u0000-\u001f\u007f]/;

/// The command, or undefined when it would not reproduce every change shown: no files, a binary
/// file, a changed file without its whole patch (an untracked file, or a patch cut short), or a
/// path git would quote.
export function applyCommand(changeSet: ChangeSet): string | undefined {
  const files = changeSet.files;
  if (files.length === 0 || (changeSet.filesOmitted ?? 0) > 0) return undefined;
  // A rename with no content change is the one change git sends without a patch.
  const renameOnly = (file: ChangedFile) => !!file.previousPath && file.additions + file.deletions === 0;
  if (files.some((file) => file.binary || file.patchTruncated || (!file.patch && !renameOnly(file)))) return undefined;
  if (files.some((file) => QUOTED.test(file.path) || QUOTED.test(file.previousPath ?? ""))) return undefined;
  const patch = files.map(filePatch).join("");
  // A patch line equal to the marker would end the here-document early.
  if (patch.split("\n").includes(MARKER)) return undefined;
  // From a subdirectory, git apply would skip every path outside it and still succeed.
  return `git -C "$(git rev-parse --show-toplevel)" apply <<'${MARKER}'\n${patch}${MARKER}\n`;
}
