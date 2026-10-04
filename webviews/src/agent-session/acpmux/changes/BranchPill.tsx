// The Branch scope's branch and the base it is compared with, under the scope pill.
import { ArrowRight } from "../changeIcons";

export function BranchPill({ branch, base }: { branch: string; base: string }) {
  return (
    <div className="acpmux-branch-pill">
      <span className="acpmux-branch-from">{branch}</span>
      <ArrowRight className="acpmux-branch-arrow" />
      <span className="acpmux-hidden-label"> compared with </span>
      <span className="acpmux-branch-to">{base}</span>
    </div>
  );
}
