// A worktree chat's branch in the header (cx-lyqio.3b, Codex/Conductor style): a chat started in a
// worktree (New Worktree, cx-lyqio.2) works on a branch of its own beside the user's checkout. The
// session host's `git.status` names the main checkout of a linked worktree (`worktree.main_root`)
// and the base the branch started from; the pill shows the branch and its tooltip both. A click
// opens them, with Apply for a chat that has work to bring back (WorktreeApply.tsx, cx-lyqio.4) and
// Remove to clean the worktree up (WorktreeRemove.tsx, cx-lyqio.5).
import { useEffect, useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { WorktreeApply } from "./WorktreeApply";
import { WorktreeRemove } from "./WorktreeRemove";
import { useWorktreeOps, type WorktreeOps } from "./worktreeOps";

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

export function WorktreePill({
  worktree,
  onApply,
  onRemove,
  folder,
  ops: suppliedOps,
}: {
  worktree: HeaderWorktree;
  folder?: string;
  ops?: WorktreeOps;
  /// Apply (WorktreeApply.tsx, cx-lyqio.4); absent for a chat with nothing to apply yet.
  onApply?: (key: string) => Promise<unknown>;
  /// Remove (WorktreeRemove.tsx, cx-lyqio.5); absent for a chat without a session yet.
  onRemove?: (key: string, discard: boolean) => Promise<unknown>;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const ownOps = useWorktreeOps(suppliedOps ? undefined : worktree, folder, onApply, onRemove);
  const ops = suppliedOps ?? ownOps;
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  const title = worktree.base
    ? t("header.worktreeFrom", { main: worktree.mainRoot, base: worktree.base })
    : t("header.worktreeOf", { main: worktree.mainRoot });
  return (
    <>
      <button
        ref={(element) => {
          buttonRef.current = element;
          setButton(element);
        }}
        type="button"
        className="acpmux-header-tool acpmux-header-worktree"
        aria-haspopup="dialog"
        aria-expanded={open}
        {...trigger}
      >
        <Icon name="git.worktree" size={13} />
        <span className="acpmux-header-worktree-name">{worktree.branch}</span>
        <span className="acpmux-header-worktree-detail">{title}</span>
      </button>
      <Popover
        open={open}
        // The pill owns opening; Base UI only reports dismissals (Escape and outside press).
        onOpenChange={(next) => {
          if (!next) setOpen(false);
        }}
        anchor={button}
        label={worktree.branch}
        className="acpmux-pr-status acpmux-worktree-status"
        side="bottom"
        finalFocus={buttonRef}
      >
        <div className="acpmux-pr-title">{worktree.branch}</div>
        <div className="acpmux-pr-facts">{title}</div>
        {ops.apply && <WorktreeApply ops={ops} />}
        {ops.canRemove && <WorktreeRemove ops={ops} />}
      </Popover>
    </>
  );
}
