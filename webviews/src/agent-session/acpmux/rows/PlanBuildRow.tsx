import { memo } from "react";
import { PlanBuildCard } from "../planBuild/PlanBuildCard";
import { type RowProps } from "./rowProps";
import { openOfferChat } from "./rowActions";

/// The builds a plan approval started off this chat (planBuild/PlanBuildCard.tsx), where it was approved.
export const PlanBuildRow = memo(
  function PlanBuildRow({ row, sessionId }: RowProps) {
    return row.planBuild ? <PlanBuildCard build={row.planBuild} sessionId={sessionId} onOpen={openOfferChat} /> : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.sessionId === b.sessionId,
);
