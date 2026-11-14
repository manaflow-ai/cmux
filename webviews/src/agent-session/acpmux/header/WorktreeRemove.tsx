// The same removal state and actions drive this popover and the native menu (worktreeOps.ts).
import { StableLabel } from "../../../ui/StableLabel";
import { useT } from "../i18n";
import type { WorktreeOps } from "./worktreeOps";
export type { Removing } from "./worktreeOps";

export function WorktreeRemove({ ops }: { ops: WorktreeOps }) {
  const t = useT();
  const { removing, remove, keep, removeMessage } = ops;
  if (removing.step === "removed") {
    return (
      <div className="acpmux-worktree-apply acpmux-worktree-remove">
        <output>{removeMessage}</output>
      </div>
    );
  }
  if (!remove) return null;
  return (
    <div className="acpmux-worktree-apply acpmux-worktree-remove">
      {removing.step === "unsaved" && <span role="alert">{removeMessage}</span>}
      {keep ? (
        <div className="acpmux-worktree-remove-confirm">
          <button
            type="button"
            className="acpmux-worktree-remove-discard"
            disabled={!remove.enabled}
            onClick={remove.run}
          >
            {remove.label}
          </button>
          <button type="button" disabled={!keep.enabled} onClick={keep.run}>
            {keep.label}
          </button>
        </div>
      ) : (
        <button type="button" disabled={!remove.enabled} onClick={remove.run}>
          <StableLabel label={remove.label} alternatives={[t("header.worktreeRemove"), t("header.worktreeRemoving")]} />
        </button>
      )}
      {removing.step === "failed" && <span role="alert">{removeMessage}</span>}
    </div>
  );
}
