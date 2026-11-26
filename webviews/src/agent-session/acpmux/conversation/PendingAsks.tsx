import type { AnswerBlock } from "../subagents/restart";
import { memo, useLayoutEffect, useRef, useSyncExternalStore, useCallback, useState, type ReactNode } from "react";
import { useT } from "../i18n";
import * as watch from "../layoutWatch";
import type { AcpmuxRow } from "../model";
import { useFold } from "./fold";
import { NextStepCard } from "./NextStepCard";
import { pinnedAsk } from "./nextStepAsk";
import { answeredAsks, askKey, subscribeAnswers } from "./waitingAskStore";
import "./PendingAsks.css";

/// Declares a move to the transcript motion model's watcher (layoutWatch.expect). It lands with the
/// motion model; until then this is a no-op.
const expectMove = (reason: string, rows: string[]) =>
  (watch as { expect?: (reason: string, move: { rows: string[]; ms: number }) => void }).expect?.(reason, {
    rows,
    ms: 0,
  });

/// The pinned list as drawn: the asks still waiting, and each one that just left (answered, dismissed,
/// settled by a prompt) kept where it stood until its fold ends (`leaving`). Each `next` ask is drawn;
/// a `prev` one not in it stays after the drawn ask it followed.
export function withLeaving(
  prev: readonly AcpmuxRow[],
  next: readonly AcpmuxRow[],
): { asks: AcpmuxRow[]; leaving: Set<string> } {
  const staying = new Set(next.map(askKey));
  const asks: AcpmuxRow[] = [];
  const leaving = new Set<string>();
  let at = 0;
  for (const row of prev) {
    const key = askKey(row);
    if (staying.has(key)) {
      // Every waiting ask up to this one, in the order the store gives.
      while (at < next.length) {
        const shown = next[at++]!;
        asks.push(shown);
        if (askKey(shown) === key) break;
      }
    } else if (!asks.some((drawn) => askKey(drawn) === key)) {
      asks.push(row);
      leaving.add(key);
    }
  }
  while (at < next.length) asks.push(next[at++]!);
  return { asks, leaving };
}

/// The pinned asks App draws (`asks`), with the ones folding out (`leaving`) and `folded`, which a
/// leaving ask's fold calls when it ends. `scope` is the chat: another chat's asks never fold here.
export function useLeavingAsks(next: readonly AcpmuxRow[], scope: string | undefined) {
  const [state, setState] = useState(() => ({
    next,
    scope,
    asks: next as readonly AcpmuxRow[],
    leaving: new Set<string>(),
  }));
  let current = state;
  // The same asks in a new array (a caller that does not memo its list) change nothing.
  const same = state.next.length === next.length && state.next.every((row, index) => row === next[index]);
  if (!same || state.scope !== scope) {
    current =
      state.scope !== scope
        ? { next, scope, asks: next, leaving: new Set<string>() }
        : { next, scope, ...withLeaving(state.asks, next) };
    setState(current);
  }
  const folded = useCallback(
    (key: string) =>
      setState((now) => {
        if (!now.leaving.has(key)) return now;
        const leaving = new Set(now.leaving);
        leaving.delete(key);
        return { ...now, asks: now.asks.filter((row) => askKey(row) !== key), leaving };
      }),
    [],
  );
  return { asks: current.asks, leaving: current.leaving as ReadonlySet<string>, folded };
}

/// One pinned ask: its "Needs your input" line and its card. Once it leaves (`leaving`) it folds out
/// on the transcript's fold clock (conversation/fold.ts), drawn as it last stood (answered at once,
/// NextStepCard.tsx) and inert, so the stack's top and the rows over it travel with it, instead of the
/// stack dropping its height in one frame (doc rule 9). Its gap in the stack, and the stack's foot when
/// it is all that is left, ride inside the fold (bottomStack.css).
function PinnedAsk({
  row,
  leaving,
  onFolded,
  children,
}: {
  row: AcpmuxRow;
  leaving: boolean;
  onFolded?: (key: string) => void;
  children: ReactNode;
}) {
  const t = useT();
  const { present, ref: foldRef } = useFold(!leaving, () => leaving, false);
  const key = askKey(row);
  useLayoutEffect(() => {
    if (!present) onFolded?.(key);
  }, [present, onFolded, key]);
  if (!present) return null;
  return (
    <section
      ref={foldRef}
      className="acpmux-pending-ask"
      aria-label={t("question.needsInput")}
      data-leaving={leaving || undefined}
      inert={leaving || undefined}
    >
      {children}
    </section>
  );
}

/// The question still waiting on the person (turns.ts `waitingAsks`: at most one per chat, its newest),
/// pinned in the bottom stack above the composer: the transcript's own card (NextStepCard.tsx), whose
/// "Needs your input" line carries the close that dismisses it. The card in the transcript stays where it
/// was asked; this copy is the one in reach. An answer goes as the person's next message, which settles
/// both. It takes the composer's ⌘↩.
export const PendingAsks = memo(function PendingAsks({
  asks,
  leaving,
  onFolded,
  onAnswer,
  registerKey,
  onDismiss,
  asker,
  blocked,
}: {
  asks: readonly AcpmuxRow[];
  /// The asks in `asks` that have left and fold out (`useLeavingAsks`); `onFolded` hears each fold end.
  /// Without them an ask answered here leaves in the click's frame.
  leaving?: ReadonlySet<string>;
  onFolded?: (key: string) => void;
  /// Why this pane cannot send, where `onAnswer` is absent (NextStepCard.tsx `blocked`).
  blocked?: AnswerBlock;
  /// Sends an answer; absent where this pane cannot send.
  onAnswer?: (text: string) => Promise<unknown>;
  registerKey?: (fire: () => void) => () => void;
  onDismiss: (key: string) => void;
  /// Who asked: an answer quotes the ask under this name (NextStepCard.tsx).
  asker?: string;
}) {
  // An ask answered from this page leaves in the click's frame, header and all (waitingAskStore.ts
  // `givenAnswer`): its answer may wait in the queue, where no prompt row settles it yet. One App
  // keeps (`leaving`) folds out instead.
  const answered = useSyncExternalStore(subscribeAnswers, answeredAsks, answeredAsks);
  const shown = answered.size ? asks.filter((row) => leaving?.has(askKey(row)) || !answered.has(askKey(row))) : asks;
  // The newest ask still waiting takes the composer's empty ⌘↩; a leaving one holds nothing.
  let keyHolder: AcpmuxRow | undefined;
  for (const row of shown) if (!leaving?.has(askKey(row))) keyHolder = row;
  // An answered ask's leave is one declared move: the section and its room go in the frame it
  // drops out of the stack (at once, or once its fold out ends).
  const before = useRef<readonly AcpmuxRow[]>(shown);
  useLayoutEffect(() => {
    const now = new Set(shown.map((row) => row.id));
    const left = before.current.filter((row) => !now.has(row.id) && answered.has(askKey(row))).map((row) => row.id);
    before.current = shown;
    if (left.length) expectMove("pinned ask answered", left);
  }, [shown, answered]);
  return (
    <>
      {shown.map((row) => {
        const step = row.nextStep;
        if (!step) return null;
        return (
          <PinnedAsk key={row.id} row={row} leaving={leaving?.has(askKey(row)) ?? false} onFolded={onFolded}>
            <NextStepCard
              onDismiss={() => onDismiss(askKey(row))}
              className="ui-glass ui-glass-floats acpmux-stack-material"
              ask={pinnedAsk(step.ask)}
              onAnswer={onAnswer}
              blocked={blocked}
              registerKey={row === keyHolder ? registerKey : undefined}
              answerKey={askKey(row)}
              asker={asker}
            />
          </PinnedAsk>
        );
      })}
    </>
  );
});
