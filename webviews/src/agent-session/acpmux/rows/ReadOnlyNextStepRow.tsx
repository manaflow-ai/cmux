import { memo } from "react";
import { NextStepCard } from "../conversation/NextStepCard";
import { openReport } from "./NextStepRow";
import { type RowProps } from "./rowProps";

/// The same card where this pane cannot send: the question and its answer, no buttons. Its Try
/// shows what it would open but stays off: a chat this pane only watches may be someone else's.
export const ReadOnlyNextStepRow = memo(
  function ReadOnlyNextStepRow({ row }: RowProps) {
    return row.nextStep ? (
      <NextStepCard
        ask={row.nextStep.ask}
        answer={row.nextStep.answer}
        superseded={row.nextStep.superseded}
        onReport={openReport}
      />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
