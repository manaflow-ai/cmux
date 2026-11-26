import { memo } from "react";
import { NextStepCard } from "../conversation/NextStepCard";
import { type RowProps } from "./rowProps";

/// The same card for a shared chat's guest (conversation/readOnly.ts): read only, its last row says only
/// the owner answers.
export const ReadOnlyNextStepRow = memo(
  function ReadOnlyNextStepRow({ row }: RowProps) {
    return row.nextStep ? (
      <NextStepCard
        ask={row.nextStep.ask}
        answer={row.nextStep.answer}
        superseded={row.nextStep.superseded}
        blocked="guest"
      />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
