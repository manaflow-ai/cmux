import { memo, useSyncExternalStore } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import { answeredAsks, askKey, subscribeAnswers } from "./waitingAskStore";
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
  asker,
}: {
  asks: readonly AcpmuxRow[];
  /// Sends an answer; absent where this pane cannot send.
  onAnswer?: (text: string) => Promise<unknown>;
  registerKey?: (fire: () => void) => () => void;
  onDismiss: (key: string) => void;
  /// Who asked: an answer quotes the ask under this name (NextStepCard.tsx).
  asker?: string;
}) {
  const t = useT();
  // An ask answered from this page leaves in the click's frame, header and all (waitingAskStore.ts
  // `givenAnswer`): its answer may wait in the queue, where no prompt row settles it yet.
  const answered = useSyncExternalStore(subscribeAnswers, answeredAsks, answeredAsks);
  const shown = answered.size ? asks.filter((row) => !answered.has(askKey(row))) : asks;
  return (
    <>
      {shown.map((row, index) => {
        const step = row.nextStep;
        if (!step) return null;
        // The recap stays with the turn it sums up; the pinned copy is the question alone.
        const { recap: _recap, ...ask } = step.ask;
        return (
          <section key={row.id} className="acpmux-pending-ask" aria-label={t("question.needsInput")}>
            <div className="acpmux-pending-ask__head" data-dock-clear="">
              <span className="acpmux-pending-ask__label">{t("question.needsInput")}</span>
              <button type="button" className="acpmux-pending-ask__dismiss" onClick={() => onDismiss(askKey(row))}>
                {t("message.dismiss")}
              </button>
            </div>
            <NextStepCard
              className="ui-glass ui-glass-floats acpmux-stack-material"
              ask={ask}
              onAnswer={onAnswer}
              registerKey={index === shown.length - 1 ? registerKey : undefined}
              answerKey={askKey(row)}
              asker={asker}
            />
          </section>
        );
      })}
    </>
  );
});
