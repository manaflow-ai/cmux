// The toast for a chat acpmux settled while the pane is open (settledChats.ts): "Settled: <title> —
// PR merged", for 5 s. On a chat the pane holds it has Undo, which Cmd+Z or Ctrl+Z also presses
// while it is up; on any other it has Open (below says why). It goes in the page's own stack, never
// the native `pane.toast`, which has no actions.
import { useEffect, useEffectEvent, useState } from "react";
import type { NoticeQueue, ToastSpec } from "../../ui/NoticeStack";
import { type Translate, translate } from "./i18n";
import { createSettleWatch, isSettleUndoKey, settledToastText } from "./settledChats";
import type { AcpmuxSessionEntry } from "./sessionList";

/// How long a settle toast stays up.
export const SETTLE_TOAST_MS = 5000;
/// The settle toasts' group: where one was dragged, the next shows.
export const SETTLE_TOAST_GROUP = "settled";

/// The toast for `entry`, with Undo when `undo` is given, else Open when `open` is. The app relays
/// `_acpmux/archive` only for a chat in the pane's scope (AcpmuxPaneMethods `sessionScoped`), so
/// Undo is only for a chat the pane holds; Open opens any other the way a Home row does, and that
/// open brings it into scope.
export function settledToast(
  entry: AcpmuxSessionEntry,
  { undo, open }: { undo?: () => void; open?: () => void },
  now = Date.now(),
  t: Translate = translate,
): ToastSpec & { id: string } {
  const action = undo
    ? { id: "undo", label: t("settle.undo"), onSelect: undo }
    : open && { id: "open", label: t("settle.open"), onSelect: open };
  return {
    id: `settled:${entry.peer ?? ""}:${entry.sessionId}`,
    message: settledToastText(entry, now, t),
    group: SETTLE_TOAST_GROUP,
    duration: SETTLE_TOAST_MS,
    ...(action && { actions: [action] }),
  };
}

const paneInFront = () => document.visibilityState !== "hidden" && document.hasFocus();

/// One settle toast still up, newest last; `undo` only on one with Undo.
export type ShownSettle = { id: string; undo?: () => void };

/// What Cmd+Z presses: the newest settle toast still up, if it has Undo. One with Open leaves
/// nothing to press, so an older toast's chat is never the one undone; once it closes, the one
/// under it is the newest again.
export function settleUndoTarget(shown: readonly ShownSettle[]): ShownSettle | undefined {
  const newest = shown.at(-1);
  return newest?.undo ? newest : undefined;
}

/// Shows a settle toast for each chat that settles while the pane is open. `holds` says whether a
/// chat is one this pane holds (its Undo is `unsettle`); any other gets `open`.
export function useSettledToasts({
  sessions,
  toasts,
  holds,
  unsettle,
  open,
  t,
}: {
  sessions: readonly AcpmuxSessionEntry[];
  toasts: NoticeQueue;
  holds: (entry: AcpmuxSessionEntry) => boolean;
  unsettle: (entry: AcpmuxSessionEntry) => void;
  open: (sessionId: string) => void;
  t: Translate;
}): void {
  const [watch] = useState(createSettleWatch);
  // The settle toasts still up, newest last (settleUndoTarget).
  const [shown, setShown] = useState<readonly ShownSettle[]>([]);
  const up = settleUndoTarget(shown);
  const showSettled = useEffectEvent((settled: readonly AcpmuxSessionEntry[]) => {
    // Every open chat pane reads the same list: only the one the person is in says it, so a settle
    // is one toast, and a hidden pane never shows a stale one when it comes back.
    if (settled.length === 0 || !paneInFront()) return;
    for (const entry of settled) {
      const undo = holds(entry) ? () => unsettle(entry) : undefined;
      const spec = settledToast(entry, { undo, open: () => open(entry.sessionId) }, Date.now(), t);
      toasts.show({
        ...spec,
        onClose: () => setShown((list) => list.filter((item) => item.id !== spec.id)),
      });
      setShown((list) => [...list.filter((item) => item.id !== spec.id), { id: spec.id, undo }]);
    }
  });
  // Only a new list is news: the callbacks and strings are read when one comes.
  // A second run on the same list (StrictMode) reads it as no change.
  useEffect(() => {
    showSettled(watch(sessions));
  }, [sessions, watch]);
  useEffect(() => {
    if (!up) return;
    const onKey = (event: KeyboardEvent) => {
      if (!isSettleUndoKey(event)) return;
      event.preventDefault();
      event.stopPropagation();
      // Closing it as answered runs its onClose, which takes it off `shown`.
      toasts.close(up.id, "action");
      up.undo?.();
    };
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [up, toasts]);
}
