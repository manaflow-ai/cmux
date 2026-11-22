import { memo } from "react";
import { NextStepCard } from "../conversation/NextStepCard";
import { type RowProps } from "./rowProps";

/// The same card where this pane cannot send: the question and its answer, no buttons.
export const ReadOnlyNextStepRow = memo(
  function ReadOnlyNextStepRow({ row }: RowProps) {
    return row.nextStep ? (
      <NextStepCard ask={row.nextStep.ask} answer={row.nextStep.answer} superseded={row.nextStep.superseded} />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
