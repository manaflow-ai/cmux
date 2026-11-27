// A running time as its own leaf: the only part of the composer's hat (SubagentTray.tsx) that the
// clock's second draws. The hat, its header and its lines used to read the clock themselves, so every
// second drew all of them again, with every Tick, mark and menu in them, while the person scrolled a
// running turn (Leo, 2026-11-09: "im still sometimes seeing a flicker on the composer/composer hat when
// scrolling and things are running in background aka time is ticking"). Now they draw on an event (a
// line joins, ends or changes its words) and the second changes one text node, in place: no element is
// added or removed, and the time's tabular figures (`acpmux-summary-meta`) keep its width from moving
// what sits beside it.
import { useState, type ReactNode } from "react";
import { Clock } from "../../../ui/Typography";
import { formatDuration } from "../conversation/turns";
import { groupElapsed, subagentTime, ticking, useNow } from "./subagentGroupModel";
import type { Subagent } from "./subagentFold";

/// How long something has run, as formatDuration writes it: from `since` to `until`, or to now while
/// `until` is unset, then ticking each second on the page clock (subagentGroupModel.ts `useNow`, which
/// counts on the session's clock and rests while the page is hidden). An ended time reads no clock.
/// `ended`: it ended with no end time known (a finished subagent whose report has no `endedAt`): its
/// time stops where it was when it ended, never counting on.
/// `clock`: the time is its own element, a `Clock` with this class, as wide as the widest text of its
/// shape (ui/Typography.tsx), so a tick never moves what sits after it (the hat's summary time).
export function Elapsed({
  since,
  until,
  ended = false,
  clock,
}: {
  since: number;
  until?: number;
  ended?: boolean;
  clock?: string;
}): ReactNode {
  const now = useNow(until === undefined && !ended);
  const [stoppedAt, setStoppedAt] = useState<number | undefined>(ended ? now : undefined);
  if (ended && stoppedAt === undefined) setStoppedAt(now);
  else if (!ended && stoppedAt !== undefined) setStoppedAt(undefined);
  const text = formatDuration(Math.max(0, (until ?? (ended ? (stoppedAt ?? now) : now)) - since));
  return clock === undefined ? text : <Clock className={clock} text={text} />;
}

/// A subagent's elapsed label owns its page-clock subscription. The row that contains it can keep
/// its identity and layout while this text changes once per second.
export function SubagentElapsed({ agent, clock }: { agent: Subagent; clock?: string }): ReactNode {
  const now = useNow(ticking(agent));
  const text = subagentTime(agent, now);
  return text === undefined ? null : clock === undefined ? text : <Clock className={clock} text={text} />;
}

/// The grouped transcript line's clock is a leaf too. Its header only re-renders when the group
/// changes, while this label follows the shared page clock.
export function GroupElapsed({ agents, clock }: { agents: readonly Subagent[]; clock?: string }): ReactNode {
  const now = useNow(agents.some(ticking));
  const text = formatDuration(groupElapsed(agents, now));
  return clock === undefined ? text : <Clock className={clock} text={text} />;
}
