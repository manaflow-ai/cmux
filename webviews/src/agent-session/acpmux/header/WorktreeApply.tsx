// The shared operation state outlives this popover's content (worktreeOps.ts).
import type { WorktreeOps } from "./worktreeOps";
export type { Applying } from "./worktreeOps";

export function WorktreeApply({ ops }: { ops: WorktreeOps }) {
  const { applying, apply, applyMessage } = ops;
  if (!apply) return null;
  return (
    <div className="acpmux-worktree-apply">
      {applying.step === "applied" && <output>{applyMessage}</output>}
      {/* Work the agent does later applies again, as a new action. */}
      <button type="button" disabled={!apply.enabled} onClick={apply.run}>
        {apply.label}
      </button>
      {applying.step === "failed" && <span role="alert">{applyMessage}</span>}
    </div>
  );
}
