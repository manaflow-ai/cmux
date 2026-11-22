// The Branch scope's branch and the base it is compared with, under the scope pill.
import { ArrowRight } from "../changeIcons";
import { useT } from "../i18n";

export function BranchPill({ branch, base }: { branch: string; base: string }) {
  const t = useT();
  return (
    <div className="acpmux-branch-pill">
      <span className="acpmux-branch-from">{branch}</span>
      <ArrowRight className="acpmux-branch-arrow" />
      <span className="acpmux-hidden-label"> {t("changes.comparedWith")} </span>
      <span className="acpmux-branch-to">{base}</span>
    </div>
  );
}
