import { memo, useSyncExternalStore, useLayoutEffect, useRef } from "react";
import { DismissButton } from "../../../ui/DismissButton";
import { useT } from "../i18n";
import * as watch from "../layoutWatch";
import type { AcpmuxRow } from "../model";
import { NextStepCard } from "./NextStepCard";
import { pinnedAsk } from "./nextStepAsk";
import { askKey, answeredAsks, subscribeAnswers } from "./waitingAskStore";
import "./PendingAsks.css";

/// Declares a move to the transcript motion model's watcher (layoutWatch.expect). It lands with the
/// motion model; until then this is a no-op.
const expectMove = (reason: string, rows: string[]) =>
  (watch as { expect?: (reason: string, move: { rows: string[]; ms: number }) => void }).expect?.(reason, {
    rows,
    ms: 0,
  });

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
  // An ask answered from this page leaves in the click's frame, header and all (waitingAskStore.ts
  // `givenAnswer`): its answer may wait in the queue, where no prompt row settles it yet.
  const answered = useSyncExternalStore(subscribeAnswers, answeredAsks, answeredAsks);
  const shown = answered.size ? asks.filter((row) => !answered.has(askKey(row))) : asks;
  // An answered ask's leave is one declared move: the section and its room go in the click's frame,
  // the frame the transcript's card folds in.
  const before = useRef<readonly AcpmuxRow[]>(shown);
  useLayoutEffect(() => {
    const left = before.current.filter((row) => answered.has(askKey(row))).map((row) => row.id);
    before.current = shown;
    if (left.length) expectMove("pinned ask answered", left);
  }, [shown, answered]);
  return (
    <>
      {shown.map((row, index) => {
        const step = row.nextStep;
        if (!step) return null;
        return (
          <section
            key={row.id}
            className="acpmux-pending-ask acpmux-pending-ask--card ui-glass ui-glass-floats acpmux-stack-material"
            aria-label={t("question.needsInput")}
          >
            <div className="acpmux-pending-ask__head" data-dock-clear="">
              <span className="acpmux-pending-ask__mark" aria-hidden="true" />
              <span className="acpmux-pending-ask__label">{t("question.needsInput")}</span>
              <DismissButton
                className="acpmux-pending-ask__dismiss"
                label={t("message.dismiss")}
                onDismiss={() => onDismiss(askKey(row))}
              />
            </div>
            <NextStepCard
              ask={pinnedAsk(step.ask)}
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
