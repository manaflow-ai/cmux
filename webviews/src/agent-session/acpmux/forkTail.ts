// A fork's tab draws the fork at once from the chat it was forked from (Leo, 2026-11-06: "just the
// fork does what you'd expect ... just make it fast and make it work well").
//
// Fork Conversation opens the fork in a tab of its own (App.tsx `chat.forkTo`), a new page that
// held nothing of it: its open read the fork from acpmux cold and faded it in, about a third of a
// second after its pane showed (scripts/cmux-next/fork-open-bench.py). Yet the forking page holds
// the fork's history already: acpmux's fork by reference shows the chat's transcript records
// through the fork's seq under their own seqs (acpmux `store/fork_view.rs`, `HISTORY_KINDS`), and
// the fork's own records start past it. So the forking page hands those rows to the app host as
// the fork's tail (tailCache.ts) before it asks for the tab, and the fork's page draws them on the
// frame it opens, as it draws any chat it read before, with no fade.
//
// Only rows proven the fork's are handed over, and the fork's page checks them again:
//   - acpmux's reply names where the fork branched (`forkSeq`) and how far its log goes
//     (`lastSeq`). A fork that copied the history renumbered it from 1, so its log ends at or
//     below `forkSeq` (or is the whole chat, record for record); one by reference starts past it.
//   - the fork's page lays acpmux's first page over the rows it drew, and keeps them only when that
//     page holds the same record at every seq the two share (`sameForkHistory`). Any other answer
//     (a copy whose log ran past `forkSeq`, a store that changed) is a chat the rows are not of:
//     the page alone is the fork, as for any tail of another session.
import type { EventRecord } from "./direct";
import { KEPT_EVENTS, type KeptTail } from "./tailCache";

/// The records a fork shows of its chat (acpmux `store/fork_view.rs` `HISTORY_KINDS`).
export const FORK_HISTORY_KINDS: ReadonlySet<string> = new Set([
  "user_message",
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update",
  "plan",
  "turn_started",
  "turn_result",
  "turn_end",
]);

/// What the forking page holds of the chat it forked.
export type ForkSource = {
  /// The chat's records the page holds, oldest first.
  events: EventRecord[];
  /// Whether `events` reach back to the chat's first record.
  historyExhausted: boolean;
  /// The record that opens the turn `events` starts in, when it is older than them.
  turnOpener: EventRecord | undefined;
};

/// The fork's tail, from the forking page's rows and acpmux's fork reply (its session summary), or
/// undefined when those rows cannot be shown as the fork's: the reply does not say where the fork
/// branched, its log is a renumbered copy, or the page does not hold the chat that far.
export function forkHistoryTail(source: ForkSource, reply: Record<string, unknown> | undefined): KeptTail | undefined {
  const forkSeq = reply?.forkSeq;
  const lastSeq = reply?.lastSeq;
  if (typeof forkSeq !== "number" || typeof lastSeq !== "number" || typeof reply?.createdAt !== "number") return;
  // A copy renumbers the history from 1 and ends at or below `forkSeq`; a fork by reference
  // appends its own records (its `forked` first) past it.
  if (lastSeq <= forkSeq) return;
  // `forkSeq` counts every record of the chat, its wire traffic too, which an attached page is not
  // sent: the page's own newest seq is often below it with all the history in hand. A record of the
  // history the page has not got yet is caught by the fork's attach (`sameForkHistory`).
  const history = source.events.filter((event) => event.seq <= forkSeq && FORK_HISTORY_KINDS.has(event.kind));
  const events = history.slice(-KEPT_EVENTS);
  const first = events[0];
  if (!first) return;
  // The turn the kept page starts in, when its opener is older than the page (as `rememberCurrentTail`).
  let turnOpener: EventRecord | undefined;
  if (!startsTurn(first)) {
    turnOpener = source.turnOpener && source.turnOpener.seq < first.seq ? source.turnOpener : undefined;
    for (let index = history.length - events.length - 1; index >= 0; index -= 1) {
      const event = history[index]!;
      if (startsTurn(event)) {
        turnOpener = event;
        break;
      }
    }
  }
  return {
    events,
    // The fork's own summary: its id and its `createdAt`, which its attach compares the rows with.
    summary: { ...reply },
    turnOpener,
    historyExhausted: source.historyExhausted && events.length === history.length,
    queue: [],
    configSeq: 0,
    // The chat's usage records are not the fork's history: the fork counts its own.
    usageFromSeq: forkSeq + 1,
    forkedThrough: forkSeq,
  };
}

/// Whether acpmux's attach page of a fork holds, at every seq through `through` that both it and
/// the rows drawn as the fork's history cover, the same record: same kind, time, direction and
/// message. A record of either that the other lacks there fails it. Older records only the page
/// holds (a page that reads further back than the tail kept) are the fork's history before it.
export function sameForkHistory(page: EventRecord[], drawn: EventRecord[], through: number): boolean {
  const drawnHistory = drawn.filter((event) => event.seq <= through);
  const pageHistory = page.filter((event) => event.seq <= through);
  if (pageHistory.length === 0 || drawnHistory.length === 0) return true;
  const oldest = (events: EventRecord[]) => events.reduce((min, event) => Math.min(min, event.seq), Infinity);
  const from = Math.max(oldest(pageHistory), oldest(drawnHistory));
  const shared = pageHistory.filter((event) => event.seq >= from);
  const drawnBySeq = new Map<number, EventRecord>();
  for (const event of drawnHistory) if (event.seq >= from) drawnBySeq.set(event.seq, event);
  if (drawnBySeq.size !== shared.length) return false;
  for (const event of shared) {
    const kept = drawnBySeq.get(event.seq);
    if (!kept || kept.kind !== event.kind || kept.at !== event.at || kept.dir !== event.dir) return false;
    if (JSON.stringify(kept.msg) !== JSON.stringify(event.msg)) return false;
  }
  return true;
}

function startsTurn(event: EventRecord): boolean {
  return event.kind === "user_message" || event.kind === "turn_started";
}
