// The clock a list's order and groups read: it moves only at the moment one of its items changes
// group (a running subagent turns idle), never each second. A list that read the second clock sorted
// and split all of its items on every tick while one ran; with this one it sorts when its items
// change or when one of them crosses its deadline, and the times on its rows tick in leaves of their
// own (Leo: "we draw the visible area, right? Like, that's what we're supposed to do").
import { useContext, useEffect, useMemo, useState } from "react";
import { subscribePageDeadline } from "../../../ui/pageClock";
import { SubagentClockContext } from "../subagents/subagentGroupModel";

/// The session's time (SubagentClockContext), as of the last moment the list's order could change:
/// `nextChange(now)` is the next session time after `now` at which it does, or undefined for none.
/// One shared page deadline timer (ui/pageClock.ts `subscribePageDeadline`) wakes it then, and only
/// then; a hidden page catches up when it shows. A deadline already past when the items change (an
/// item that went quiet long ago) fires at once, so the order is never left stale.
export function useStatusClock(nextChange: (now: number) => number | undefined): number {
  const offset = useContext(SubagentClockContext);
  const [now, setNow] = useState(() => Date.now() - offset);
  const due = useMemo(() => nextChange(now), [nextChange, now]);
  useEffect(() => {
    if (due === undefined) return;
    // The page's deadline clock asks for the next deadline on subscribing and again after each
    // wake: this subscription has one, and the render that wake causes subscribes the next.
    let asked = 0;
    return subscribePageDeadline(
      () => setNow(Date.now() - offset),
      () => (asked++ === 0 ? due + offset : Number.POSITIVE_INFINITY),
    );
  }, [due, offset]);
  return now;
}
