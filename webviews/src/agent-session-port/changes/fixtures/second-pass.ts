// The real working-tree diff of the "UI Atlas Fixtures" repository after the second pass
// (reference/codex-fixture-second-pass.patch, `git diff` of 12 tracked files). The Changes
// captures of that repository all failed to load, so this set is what Retry would show.
import patchText from "./second-pass.patch?raw";
import type { ChangedFile, ChangeSet } from "../model";

/** Split a multi-file `git diff` into per-file patches with counts and status. */
export function parseGitDiff(text: string): ChangedFile[] {
  const chunks = text.split(/^(?=diff --git )/m).filter((c) => c.startsWith("diff --git "));
  return chunks.map((chunk) => {
    const [, a, b] = /^diff --git a\/(.+?) b\/(.+)$/m.exec(chunk) ?? [];
    const binary = /^GIT binary patch$/m.test(chunk);
    const lines = chunk.split("\n");
    const body = lines.filter((l) => !l.startsWith("+++") && !l.startsWith("---"));
    const status: ChangedFile["status"] = /^deleted file mode/m.test(chunk)
      ? "deleted"
      : /^new file mode/m.test(chunk)
        ? "added"
        : a !== b
          ? "renamed"
          : "modified";
    return {
      path: b,
      previousPath: a !== b ? a : undefined,
      status,
      additions: binary ? 0 : body.filter((l) => l.startsWith("+")).length,
      deletions: binary ? 0 : body.filter((l) => l.startsWith("-")).length,
      // Binary bodies are not text diffs; keep only the header so the file still lists.
      patch: binary ? lines.slice(0, lines.indexOf("GIT binary patch")).join("\n") + "\n" : chunk,
    };
  });
}

export const secondPassChanges: ChangeSet = {
  scope: "uncommitted",
  files: parseGitDiff(patchText),
};
