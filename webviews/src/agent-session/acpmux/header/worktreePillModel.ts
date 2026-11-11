import { useEffect, useRef, useState, useSyncExternalStore } from "react";

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

/// The folders this page asked for: the first read of a folder never waits for the page to show.
const askedFolders = new Set<string>();

function subscribeShown(changed: () => void): () => void {
  document.addEventListener("visibilitychange", changed);
  return () => document.removeEventListener("visibilitychange", changed);
}

/// Whether someone can see the page: false behind another tab or in a workspace that does not show.
const pageShown = () => document.visibilityState !== "hidden";

/// The worktree of the chat's folder (a new chat's picked folder too), read again when the folder
/// changes and when `refresh` does (the chat starts or ends a turn, which may switch its branch). A
/// reply for a folder the chat has left is dropped.
///
/// A chat nobody looks at owes its refresh until it shows, and then reads once for all the turns
/// since: each read is a git process of the session host, and the chats that end turns in a burst
/// ran them in front of the `git.status` of the view the person looked at (Chrome throttles the work
/// of a page that is not shown the same way). The first read of a folder does not wait, so the pill
/// is there in the first frame the person sees.
export function useWorktree(
  folder: string | undefined,
  readStatus: ((cwd: string) => Promise<unknown>) | undefined,
  refresh?: unknown,
): HeaderWorktree | undefined {
  const [found, setFound] = useState<{ folder: string; worktree: HeaderWorktree | undefined }>();
  const shown = useSyncExternalStore(subscribeShown, pageShown, () => true);
  // The read asked last: its reply is the one that shows, and a page that shows again with no
  // turn since asks nothing.
  const asked = useRef<{ folder: string; refresh: unknown }>(undefined);
  // A refresh came while nobody could see the page: a turn that started and ended there leaves
  // `refresh` as it was, so the debt is kept by itself.
  const owed = useRef(false);
  useEffect(() => {
    if (!folder || !readStatus) return;
    const last = asked.current;
    const same = last !== undefined && last.folder === folder && Object.is(last.refresh, refresh);
    if (same && !owed.current) return;
    if (!shown && askedFolders.has(folder)) {
      owed.current = true;
      return;
    }
    owed.current = false;
    const ask = { folder, refresh };
    asked.current = ask;
    askedFolders.add(folder);
    readStatus(folder).then(
      (value) => {
        const worktree = worktreeOf(value);
        knownWorktrees.set(folder, worktree);
        if (asked.current === ask) setFound({ folder, worktree });
      },
      // A folder that no longer reads (a removed worktree) shows no pill, and is forgotten.
      () => {
        knownWorktrees.delete(folder);
        if (asked.current === ask) setFound({ folder, worktree: undefined });
      },
    );
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the status is the folder's: a new reader asks nothing new
  }, [folder, refresh, shown]);
  if (!folder || !readStatus) return undefined;
  return found?.folder === folder ? found.worktree : knownWorktrees.get(folder);
}
