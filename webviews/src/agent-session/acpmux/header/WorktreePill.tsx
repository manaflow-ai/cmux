// A worktree chat's branch in the header (cx-lyqio.3b, Codex/Conductor style): a chat started in a
// worktree (New Worktree, cx-lyqio.2) works on a branch of its own beside the user's checkout. The
// session host's `git.status` names the main checkout of a linked worktree (`worktree.main_root`)
// and the base the branch started from; the pill shows the branch and its tooltip both.
import { useEffect, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";

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
      (value) => current && setFound({ folder, worktree: worktreeOf(value) }),
      () => current && setFound({ folder, worktree: undefined }),
    );
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the status is the folder's: a new reader asks nothing new
  }, [folder, refresh]);
  return folder && readStatus && found?.folder === folder ? found.worktree : undefined;
}

export function WorktreePill({ worktree }: { worktree: HeaderWorktree }) {
  const t = useT();
  const title = worktree.base
    ? t("header.worktreeFrom", { main: worktree.mainRoot, base: worktree.base })
    : t("header.worktreeOf", { main: worktree.mainRoot });
  return (
    <span className="acpmux-header-worktree" title={title}>
      <Icon name="git.worktree" size={13} />
      <span className="acpmux-header-worktree-name">{worktree.branch}</span>
      <span className="acpmux-header-worktree-detail">{title}</span>
    </span>
  );
}
