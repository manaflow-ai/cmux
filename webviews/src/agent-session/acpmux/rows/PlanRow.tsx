// The `plan` row: the agent's todo list.
import { memo } from "react";
import { PlanList } from "../conversation/PlanList";
import type { RowProps } from "./rowProps";

export const PlanRow = memo(
  function PlanRow({ row }: RowProps) {
    return row.plan ? (
      <PlanList entries={row.plan} ended={row.turnEnded} />
    ) : (
      <div className="acpmux-muted">{row.text}</div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
