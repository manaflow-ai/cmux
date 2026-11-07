import { memo, useContext } from "react";
import { TurnActionsContext } from "../conversation/turnActions";
import { NextStepCard } from "../conversation/NextStepCard";
import { type RowProps } from "./rowProps";

/// A tagged ask the turn's answer ended on, as a card with its answers (conversation/NextStepCard.tsx).
export const NextStepRow = memo(
  function NextStepRow({ row }: RowProps) {
    const { answer, nextStepKey } = useContext(TurnActionsContext);
    return row.nextStep ? (
      <NextStepCard
        ask={row.nextStep.ask}
        answer={row.nextStep.answer}
        superseded={row.nextStep.superseded}
        onAnswer={answer}
        registerKey={nextStepKey}
      />
    ) : null;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
