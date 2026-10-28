// The `workflowCard` row: a Claude workflow's card.
import { memo } from "react";
import { WorkflowCard } from "../summary/WorkflowCard";
import type { RowProps } from "./rowProps";

/// A Claude workflow's card where it started (Labs, summary/WorkflowCard.tsx).
export const WorkflowCardRow = memo(
  function WorkflowCardRow({ row }: RowProps) {
    return (
      <>
        {(row.subagents ?? []).map((node) => (
          <WorkflowCard key={node.id} node={node} />
        ))}
      </>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
