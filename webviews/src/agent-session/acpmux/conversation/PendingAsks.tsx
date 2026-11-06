import { memo } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import { askKey } from "./waitingAskStore";
import "./PendingAsks.css";

/// The questions still waiting on the person (waitingAskStore.ts), pinned in the bottom stack above the
/// composer, oldest first, each the transcript's own card (NextStepCard.tsx) under the "Needs your input" line the
/// live question card uses, with its Dismiss. The card in the transcript stays where it was asked; this copy is the
/// one in reach. An answer goes as the person's next message, which settles both. The newest takes
/// the composer's ⌘↩.
export const PendingAsks = memo(function PendingAsks({
  asks,
  onAnswer,
  registerKey,
  onDismiss,
}: {
  asks: readonly AcpmuxRow[];
  /// Sends an answer; absent where this pane cannot send.
  onAnswer?: (text: string) => Promise<unknown>;
  registerKey?: (fire: () => void) => () => void;
  onDismiss: (key: string) => void;
}) {
  const t = useT();
  return (
    <>
      {asks.map((row, index) => {
        const step = row.nextStep;
        if (!step) return null;
        // The recap stays with the turn it sums up; the pinned copy is the question alone.
        const { recap: _recap, ...ask } = step.ask;
        return (
          <section key={row.id} className="acpmux-pending-ask" aria-label={t("question.needsInput")}>
            <div className="acpmux-pending-ask__head">
              <span className="acpmux-pending-ask__label">{t("question.needsInput")}</span>
              <button type="button" className="acpmux-pending-ask__dismiss" onClick={() => onDismiss(askKey(row))}>
                {t("message.dismiss")}
              </button>
            </div>
            <NextStepCard
              ask={ask}
              onAnswer={onAnswer}
              registerKey={index === asks.length - 1 ? registerKey : undefined}
              answerKey={askKey(row)}
            />
          </section>
        );
      })}
    </>
  );
});
