import { useEffect, useState } from "react";

export interface HeaderWorktree {
  readonly branch: string;
  readonly base: string;
  readonly mainRoot: string;
}

/// The worktree a `git.status` answer describes, or undefined for a plain checkout or detached head.
export function worktreeOf(value: unknown): HeaderWorktree | undefined {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const worktree = (raw.worktree && typeof raw.worktree === "object" ? raw.worktree : {}) as Record<string, unknown>;
  const text = (field: unknown) => (typeof field === "string" ? field : "");
  const branch = text(raw.branch);
  const mainRoot = text(worktree.main_root);
  if (raw.detached === true || !branch || !mainRoot) return undefined;
  return { branch, base: text(raw.base), mainRoot };
}

/// The last worktree read for each folder on this page: a chat in a folder read before draws its
/// pill in the first render and the read only refreshes it, instead of the pill leaving and coming
/// back (pushing the header tools) on every chat switch (Leo 2026-10-19).
const knownWorktrees = new Map<string, HeaderWorktree | undefined>();

/// The worktree of the chat's folder (a new chat's picked folder too), read again when the folder
/// changes and when `refresh` does (the chat starts or ends a turn, which may switch its branch). A
/// reply for a folder the chat has left is dropped.
export function useWorktree(
  folder: string | undefined,
  readStatus: ((cwd: string) => Promise<unknown>) | undefined,
  refresh?: unknown,
): HeaderWorktree | undefined {
  const [found, setFound] = useState<{ folder: string; worktree: HeaderWorktree | undefined }>();
  useEffect(() => {
    if (!folder || !readStatus) return;
    let current = true;
    readStatus(folder).then(
      (value) => {
        const worktree = worktreeOf(value);
        knownWorktrees.set(folder, worktree);
        if (current) setFound({ folder, worktree });
      },
      // A folder that no longer reads (a removed worktree) shows no pill, and is forgotten.
      () => {
        knownWorktrees.delete(folder);
        if (current) setFound({ folder, worktree: undefined });
      },
    );
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the status is the folder's: a new reader asks nothing new
  }, [folder, refresh]);
  if (!folder || !readStatus) return undefined;
  return found?.folder === folder ? found.worktree : knownWorktrees.get(folder);
}
