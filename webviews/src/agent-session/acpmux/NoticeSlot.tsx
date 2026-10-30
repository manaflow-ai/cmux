import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";

/// How much a notice above the composer matters (hq#2569 #12): an error beats what is happening
/// now, which beats a hint, which beats an update the person started, which beats standing
/// information that is always there (the agent rules card). Higher wins.
export const NOTICE_TIER = { error: 40, status: 30, hint: 20, update: 10, info: 5 } as const;
export type NoticeTier = keyof typeof NOTICE_TIER;

type Entry = { tier: number; order: number };
type Slot = {
  shown: string | undefined;
  claim(id: string, tier: number): void;
  release(id: string): void;
};

const SlotContext = createContext<Slot | undefined>(undefined);

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

/// The notice that draws: the highest tier, then the one that asked first.
export function topNotice(entries: ReadonlyMap<string, Entry>): string | undefined {
  let best: [string, Entry] | undefined;
  for (const entry of entries) {
    const [, value] = entry;
    if (!best || value.tier > best[1].tier || (value.tier === best[1].tier && value.order < best[1].order))
      best = entry;
  }
  return best?.[0];
}

/// A notice's turn in the slot: `wants` says it has something to show; `shown` is whether it
/// draws now. The claim lands in a layout effect, so a lower notice never paints under a higher one.
export function useNoticeTurn(id: string, tier: NoticeTier, wants: boolean): { shown: boolean } {
  const slot = useContext(SlotContext);
  const rank = NOTICE_TIER[tier];
  const claim = slot?.claim;
  const release = slot?.release;
  useLayoutEffect(() => {
    if (!claim || !release) return;
    if (wants) claim(id, rank);
    else release(id);
  }, [claim, release, id, rank, wants]);
  useLayoutEffect(() => () => release?.(id), [release, id]);
  if (!slot) return { shown: wants };
  return { shown: wants && slot.shown === id };
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
