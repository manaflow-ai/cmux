import { memo } from "react";
import { DismissButton } from "../../../ui/DismissButton";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import { askKey } from "./waitingAskStore";
import "./PendingAsks.css";

/// The questions still waiting on the person (waitingAskStore.ts), pinned in the bottom stack above the
/// composer, oldest first, each the transcript's own card (NextStepCard.tsx) in one stack card whose
/// head row says "Needs your input" with the attention mark and closes with the shared × (Dismiss),
/// as Claude desktop's recap card and Codex's review card put their × in the card's corner. Leo,
/// 2026-11-19, on the line over a separate card: "odd looking". The card in the transcript stays
/// where it was asked; this copy is the one in reach. An answer goes as the person's next message,
/// which settles both. The newest takes the composer's ⌘↩. Looks compared:
/// NeedsInputCardLooks.gallery.tsx.
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
  return (
    <>
      {asks.map((row, index) => {
        const step = row.nextStep;
        if (!step) return null;
        // The recap stays with the turn it sums up; the pinned copy is the question alone.
        const { recap: _recap, ...ask } = step.ask;
        return (
          <section
            key={row.id}
            className="acpmux-pending-ask acpmux-pending-ask--card ui-glass ui-glass-floats acpmux-stack-material"
            aria-label={t("question.needsInput")}
          >
            <div className="acpmux-pending-ask__head">
              <span className="acpmux-pending-ask__mark" aria-hidden="true" />
              <span className="acpmux-pending-ask__label">{t("question.needsInput")}</span>
              <DismissButton
                className="acpmux-pending-ask__dismiss"
                label={t("message.dismiss")}
                onDismiss={() => onDismiss(askKey(row))}
              />
            </div>
            <NextStepCard
              ask={ask}
              onAnswer={onAnswer}
              registerKey={index === asks.length - 1 ? registerKey : undefined}
              answerKey={askKey(row)}
              asker={asker}
            />
          </section>
        );
      })}
    </>
  );
});
