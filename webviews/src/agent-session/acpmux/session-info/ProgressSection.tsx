// Live checklist progress in Session Info, matching the compact progress rail in ChatGPT.
import { memo } from "react";
import { PlanList } from "../conversation/PlanList";
import type { AcpmuxPlanEntry } from "../model";

export const ProgressSection = memo(function ProgressSection({
  plan,
  ended = false,
}: {
  plan: readonly AcpmuxPlanEntry[];
  ended?: boolean;
}) {
  return (
    <div className="acpmux-session-info-progress">
      <PlanList entries={plan} ended={ended} />
    </div>
  );
});
