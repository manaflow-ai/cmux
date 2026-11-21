import { memo, type ReactNode, useCallback, useMemo, useRef, useState } from "react";
import { type NoticeTier, type Entry, SlotContext, topNotice, useNoticeTurn } from "./noticeSlotModel";
import { useCountedRender } from "./perfRender";
/// The one place above the composer where notices show: of every notice that wants to show, only
/// the highest tier draws (the first to ask, on a tie); the rest wait, mounted with their state,
/// and show once it clears. Notices outside a slot (a gallery, a test) always draw.
export function NoticeSlot({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<ReadonlyMap<string, Entry>>(() => new Map());
  const order = useRef(0);
  const claim = useCallback((id: string, tier: number) => {
    setEntries((current) => {
      const had = current.get(id);
      if (had?.tier === tier) return current;
      const next = new Map(current);
      next.set(id, { tier, order: had?.order ?? ++order.current });
      return next;
    });
  }, []);
  const release = useCallback((id: string) => {
    setEntries((current) => {
      if (!current.has(id)) return current;
      const next = new Map(current);
      next.delete(id);
      return next;
    });
  }, []);
  const shown = topNotice(entries);
  const slot = useMemo(() => ({ shown, claim, release }), [shown, claim, release]);
  return <SlotContext.Provider value={slot}>{children}</SlotContext.Provider>;
}

type NoticeProps = {
  id: string;
  tier: NoticeTier;
  when: unknown;
  children: ReactNode;
};

/// A notice the pane draws itself (`when`): its children show only on its turn in the slot.
///
/// While it wants to show nothing, its children are not compared: it draws none of them, and the pane hands it new
/// ones on every render (inline elements, new callbacks). The pane renders on every snapshot that is not a streamed
/// chunk (a tool call, its result, a new row), so each of its ~18 notices rendered on each such event, though
/// nearly all of them show nothing (Leo, 2026-11-19: "why stuff redraw often?"). One that comes to show renders
/// then (`when` changed), with its newest children; one that shows renders for each new child, as before. Its turn
/// in the slot is context, so a change there renders it whatever its props.
export const Notice = memo(
  function Notice({ id, tier, when, children }: NoticeProps) {
    // Debug measurement (acpmuxPerf): its committed renders (NoticeSlot.test.tsx).
    useCountedRender(`notice:${id}`);
    const { shown } = useNoticeTurn(id, tier, Boolean(when));
    return shown ? <>{children}</> : null;
  },
  (previous: NoticeProps, next: NoticeProps) =>
    previous.id === next.id &&
    previous.tier === next.tier &&
    Boolean(previous.when) === Boolean(next.when) &&
    (!next.when || previous.children === next.children),
);
