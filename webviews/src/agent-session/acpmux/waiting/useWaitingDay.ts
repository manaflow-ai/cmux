// Reads the day's waiting lanes for the home (WaitingTimeline.tsx). It asks once when the home is
// shown and again after any listed chat changes status, a moment after the last change so a burst
// of changes is one read. There is no interval: the one timer is the debounce, cleared by the next
// change or when the home goes. A reply that an older ask brings after a newer one is dropped, and
// a failed read leaves the last day (or nothing) in place.
import { useEffect, useRef, useState } from "react";
import { localMidnight, parseWaitingDay, type WaitingDay } from "./waitingModel";

export type ReadWaitingDay = (params: { since: number; until: number }) => Promise<unknown>;

/** After a status change, how long the read waits for the next one. */
export const WAITING_READ_DEBOUNCE_MS = 400;

// The last day read in this page, so the home drawn again draws it at once, with no pop-in, while
// the new read is on its way. Only today's: a page left open overnight starts empty.
let lastDay: WaitingDay | undefined;

export function useWaitingDay(read: ReadWaitingDay | undefined, key: string, shown: boolean): WaitingDay | undefined {
  const [day, setDay] = useState<WaitingDay | undefined>(() =>
    lastDay && lastDay.since === localMidnight(Date.now()) ? lastDay : undefined,
  );
  const ticket = useRef(0);
  const first = useRef(true);
  useEffect(() => {
    if (!shown || !read) {
      first.current = true;
      return;
    }
    const asked = ++ticket.current;
    const ask = () => {
      const until = Date.now();
      read({ since: localMidnight(until), until }).then(
        (reply) => {
          if (asked !== ticket.current) return;
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
    return () => clearTimeout(timer);
  }, [read, key, shown]);
  return shown ? day : undefined;
}
