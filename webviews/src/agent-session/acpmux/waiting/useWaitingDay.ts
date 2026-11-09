// Reads the day's waiting lanes for the home (WaitingTimeline.tsx). It asks once when the home is
// shown and again after any listed chat changes status, a moment after the last change so a burst
// of changes is one read. There is no interval: the one timer is the debounce, cleared by the next
// change or when the home goes. A reply that an older ask brings after a newer one is dropped, and
// a failed read leaves the last day (or nothing) in place. Nothing is asked while the link to acpmux
// is down; the read runs when it comes up. A home left open past local midnight starts the new day
// then: one timer to the next midnight, cleared when the home goes.
import { useEffect, useRef, useState } from "react";
import { localMidnight, parseWaitingDay, type WaitingDay } from "./waitingModel";

export type ReadWaitingDay = (params: { since: number; until: number }) => Promise<unknown>;

/** After a status change, how long the read waits for the next one. */
export const WAITING_READ_DEBOUNCE_MS = 400;

// The last day read in this page, so the home drawn again draws it at once, with no pop-in, while
// the new read is on its way. Only today's: a page left open overnight starts empty.
let lastDay: WaitingDay | undefined;
// The newest ask of any home in this page: an older ask's reply, from this home or one gone since,
// never overwrites a newer one's.
let latestAsk = 0;

export function useWaitingDay(
  read: ReadWaitingDay | undefined,
  key: string,
  shown: boolean,
  linked = true,
): WaitingDay | undefined {
  const [day, setDay] = useState<WaitingDay | undefined>(() =>
    lastDay && lastDay.since === localMidnight(Date.now()) ? lastDay : undefined,
  );
  const [today, setToday] = useState(() => localMidnight(Date.now()));
  useEffect(() => {
    if (!shown) return;
    const next = new Date(today);
    next.setDate(next.getDate() + 1);
    const timer = setTimeout(
      () => {
        setDay(undefined);
        setToday(localMidnight(Date.now()));
      },
      Math.max(1_000, next.getTime() - Date.now()),
    );
    return () => clearTimeout(timer);
  }, [shown, today]);
  const first = useRef(true);
  useEffect(() => {
    if (!shown || !read || !linked) {
      first.current = true;
      return;
    }
    let live = true;
    const ask = () => {
      const asked = ++latestAsk;
      const until = Date.now();
      read({ since: localMidnight(until), until }).then(
        (reply) => {
          if (!live || asked !== latestAsk) return;
          const parsed = parseWaitingDay(reply);
          if (!parsed) return;
          lastDay = parsed;
          setDay(parsed);
        },
        () => undefined,
      );
    };
    // The home's first draw reads at once; a status change waits out the burst.
    const delay = first.current ? 0 : WAITING_READ_DEBOUNCE_MS;
    first.current = false;
    const timer = setTimeout(ask, delay);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [read, key, shown, linked, today]);
  return shown ? day : undefined;
}
