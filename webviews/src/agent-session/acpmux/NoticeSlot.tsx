import { type ReactNode, useCallback, useMemo, useRef, useState } from "react";
import { type NoticeTier, type Entry, SlotContext, topNotice, useNoticeTurn } from "./noticeSlotModel";
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

/// A notice the pane draws itself (`when`): its children show only on its turn in the slot.
export function Notice({
  id,
  tier,
  when,
  children,
}: {
  id: string;
  tier: NoticeTier;
  when: unknown;
  children: ReactNode;
}) {
  const { shown } = useNoticeTurn(id, tier, Boolean(when));
  return shown ? <>{children}</> : null;
}
