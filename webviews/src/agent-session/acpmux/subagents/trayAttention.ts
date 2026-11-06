// What needs the person leads the open tray's list, so the list's height cap never clips it (the
// coordinator, 2026-11-04, on four agents at 360px whose fourth line, the failed one, sat under the
// cap while the header said "1 failed"). A line needs the person when it waits on them or failed;
// the rest keep their order (runningTray.ts: what runs newest first, then what ended, latest first).
// A nested subagent moves with the top-level line it sits under, so a tree never breaks apart.
import { subagentStatus } from "../summary/SubagentStatusList";
import { sessionRetry } from "./retryState";
import type { TrayItem } from "./runningTray";
import type { StartedSession } from "../started/startedSessions";

/// One line of the open list: the item, and whether it ended (its `data-finished` card).
export type TrayCard = { readonly item: TrayItem; readonly finished: boolean };

/// A started chat waits on the person: it reads "waiting" and is not only queued for a run slot
/// (`waitsForSlot`), which waits on cmux and starts on its own.
export const asksPerson = (session: StartedSession): boolean => session.state === "waiting" && !session.waitsForSlot;

/// The item waits on the person or failed.
export function needsPerson(item: TrayItem, waiting: ReadonlySet<string>): boolean {
  if (item.kind === "agent") {
    const status = subagentStatus(item.agent, waiting);
    return status === "waiting" || status === "failed";
  }
  // A failed chat acpmux is retrying (or deciding to) is about to run again, as a retrying
  // subagent reads "running" (retryState.ts): only one that stays failed needs the person.
  if (item.kind === "session") return asksPerson(item.session) || sessionRetry(item.session).kind === "failed";
  return false;
}

/// The open list's lines: every top-level group (a line and the nested lines under it) that holds a
/// line needing the person first, in list order, then the rest in list order. One pass over the
/// lines, run when the lists change, never per tick.
export function attentionFirst(
  items: readonly TrayItem[],
  finished: readonly TrayItem[],
  waiting: ReadonlySet<string>,
): readonly TrayCard[] {
  const groups: { cards: TrayCard[]; urgent: boolean }[] = [];
  const add = (item: TrayItem, ended: boolean) => {
    const nested = item.kind === "agent" && item.depth > 0;
    const last = groups.at(-1);
    const group = nested && last ? last : { cards: [], urgent: false };
    if (group !== last) groups.push(group);
    group.cards.push({ item, finished: ended });
    if (needsPerson(item, waiting)) group.urgent = true;
  };
  for (const item of items) add(item, false);
  // An ended line never nests under a running one: the ended lines start a group of their own.
  if (finished.length > 0) groups.push({ cards: [], urgent: false });
  for (const item of finished) add(item, true);
  const ordered = [...groups.filter((group) => group.urgent), ...groups.filter((group) => !group.urgent)];
  return ordered.flatMap((group) => group.cards);
}
