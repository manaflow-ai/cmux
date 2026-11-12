// A worktree chat's branch in the header (cx-lyqio.3b, Codex/Conductor style): a chat started in a
// worktree (New Worktree, cx-lyqio.2) works on a branch of its own beside the user's checkout. The
// session host's `git.status` names the main checkout of a linked worktree (`worktree.main_root`)
// and the base the branch started from; the pill shows the branch and its tooltip both. A click
// opens them, with Apply for a chat that has work to bring back (WorktreeApply.tsx, cx-lyqio.4) and
// Remove to clean the worktree up (WorktreeRemove.tsx, cx-lyqio.5).
import { useRef, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { WorktreeApply } from "./WorktreeApply";
import { WorktreeRemove } from "./WorktreeRemove";
import { useWorktreeOps, type WorktreeOps } from "./worktreeOps";
import type { HeaderWorktree } from "./worktreePillModel";

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
        <Icon name="git.worktree" size={14} />
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
