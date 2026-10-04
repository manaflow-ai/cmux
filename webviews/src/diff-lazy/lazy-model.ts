// Prototype (plans/cmux-next/diff-perf.md): the summary-first, hunks-on-demand model. Not
// wired into App.tsx. The page asks the sidecar (feature `lazy-hunks`) for the file list
// first, then for the hunks of only the files the virtualizer renders.
import { processFile } from "@pierre/diffs";

export type LazyFile = { path: string; prevPath: string | null; status: "added" | "deleted" | "modified" | "renamed" };
export type LazyStats = Record<string, [number, number] | null>;
export type LazyPatch = { path: string; hunks: string };

export type LazyRpc = <T>(method: string, params: Record<string, unknown>) => Promise<T>;

/** A JSON RPC over the dev server's /__cmux-diff/rpc (one sidecar run per call). */
export function fetchRpc(endpoint: string, capabilityToken: string, repoRoot: string): LazyRpc {
  let next = 0;
  return async <T>(method: string, params: Record<string, unknown>) => {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: `lazy-${next++}`,
        version: 1,
        method,
        params: { capabilityToken, repoRoot, ...params },
      }),
    });
    const reply = await response.json();
    if (reply.error) throw new Error(`${method}: ${reply.error.code} ${reply.error.message}`);
    return reply.result as T;
  };
}

/** A placeholder diff with no hunks: the item renders as its header until its hunks arrive. */
export function placeholderDiff(file: LazyFile): any {
  return {
    name: file.path,
    prevName: file.prevPath ?? undefined,
    type:
      file.status === "added"
        ? "new"
        : file.status === "deleted"
          ? "deleted"
          : file.status === "renamed"
            ? "rename-changed"
            : "change",
    hunks: [],
    splitLineCount: 0,
    unifiedLineCount: 0,
    isPartial: true,
    deletionLines: [],
    additionLines: [],
    cacheKey: `lazy-placeholder:${file.path}`,
  };
}

/**
 * Pierre's parser wants the git file header that cmux-git's `parse::patches` strips, so
 * rebuild the part Pierre reads (paths, new/deleted, rename) from the summary row. A Rust
 * structured parse (design (b)) removes this step.
 */
export function fileDiffFromHunks(file: LazyFile, hunks: string, cacheKey: string): any {
  const oldPath = file.prevPath ?? file.path;
  let header = `diff --git a/${oldPath} b/${file.path}\n`;
  if (file.status === "added") header += `new file mode 100644\n--- /dev/null\n+++ b/${file.path}\n`;
  else if (file.status === "deleted") header += `deleted file mode 100644\n--- a/${file.path}\n+++ /dev/null\n`;
  else if (file.status === "renamed")
    header += `rename from ${oldPath}\nrename to ${file.path}\n--- a/${oldPath}\n+++ b/${file.path}\n`;
  else header += `--- a/${file.path}\n+++ b/${file.path}\n`;
  return processFile(header + hunks, { cacheKey, isGitDiff: true });
}

/**
 * Coalesces load requests for the files the virtualizer renders into one sidecar call per
 * frame, and never asks twice for a file.
 */
export function createPatchLoader(
  rpc: LazyRpc,
  base: string,
  onLoaded: (patches: LazyPatch[], deferred: string[], requested: string[]) => void,
) {
  const requested = new Set<string>();
  let queued: string[] = [];
  let scheduled = false;
  const flush = async () => {
    scheduled = false;
    const paths = queued.splice(0, queued.length);
    if (paths.length === 0) return;
    const result = await rpc<{ patches: LazyPatch[]; deferred?: string[] }>("lazyPatches", { base, paths });
    onLoaded(result.patches, result.deferred ?? [], paths);
  };
  return {
    request(path: string) {
      if (requested.has(path)) return;
      requested.add(path);
      queued.push(path);
      if (!scheduled) {
        scheduled = true;
        requestAnimationFrame(() => void flush());
      }
    },
  };
}
