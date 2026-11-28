import type { AcpmuxRow } from "../model";
import { type EventRecord, startsTurn, mergeEventRecords } from "./records";

/// Records one older page asks for at most (`limit`), with OLDER_PAGE_BYTES.
export const OLDER_PAGE_RECORDS = 2000;

/// The most held records a rebuild folds again (`rebuild`): a pane open on a busy chat holds every
/// record streamed since it opened, and a lag read or a repaired turn refolded all of them.
export const REBUILD_WINDOW = 5_000;
/// How many records a chat left open keeps when it lets go of its oldest (`shedOlderHeld`): a quarter of one older
/// page (`OLDER_PAGE_RECORDS`), so scrolling up past the cut still reads one page to have them back. It sets what
/// every open chat holds: at 2,000, two chats grown to 100k rows each held 4,000 records and drew 1.48x an empty
/// pair's renderer memory and 2.08x its JS heap; at 500, 1.37x and 1.64x (bench/chat-100k-flat.bench.ts grown-many;
/// Leo, 2026-11-14: "memory and cpu staying flat on infinite chats"). The page stays 2,000: a jump far back walks
/// pages, and 500-record pages took it from 27 reads to 41 (olderPagingBench.test.ts). Kept at the
/// rebuild's whole window (5,000) and shed at twice that, a chat left open held 5,000 to 10,000 records: in the
/// god log 3,000 to 6,500 rows, against a 600-turn chat's 2,800 whole, and each streamed thought and tool call
/// cost 1.5x to 1.8x that chat's (bench/transcript-replay.bench.ts, FIXTURE=god; Leo, 2026-11-12: "even if a
/// chat is long, there should be no percievable difference").
export const HELD_KEPT = OLDER_PAGE_RECORDS / 4;
/// How many records a chat left open holds before its oldest are let go (`shedOlderHeld`): twice what a cut
/// keeps, so it sheds at most once per `HELD_KEPT` records, each time dropping what leaves in place (`dropHeldRun`).
export const HELD_RECORDS = 2 * HELD_KEPT;
/// How many more records a chat that could not shed past `HELD_RECORDS` takes before it tries again
/// (`shedOlderHeld`): the try walks the newest `HELD_KEPT` records, so a refused one costs O(1) a record.
export const HELD_RETRY = HELD_KEPT / 4;

/// A row a shed kept across its cut (direct.ts `splits`): a tool call's row (`callId`, `earlier` once its oldest
/// output lines went), or a streaming reply's. `aside`: the records older than the held ones that draw it again.
export type HeldSplit =
  | { kind: "tool"; callId: string; aside: EventRecord[]; earlier: boolean }
  | { kind: "reply"; aside: EventRecord[] };
/// The client's fields a fold of records writes about the turn they are in (`foldOlder` keeps them as the live
/// chat's): a window whose newest records are left folds a page read forward with its own (`landNewer`).
export const FOLD_TURN_KEYS = [
  "turnOpen",
  "turnOpenedSeq",
  "turnStartedAtMs",
  "turnPromptAtMs",
  "turnPrompt",
  "turnTokens",
  "turnTokenSplit",
  "runningTurnId",
  "lastReplyRow",
  "streamingAssistant",
  "streamingAssistantMessageId",
  "streamingSegment",
  "assistantCut",
  "streamingActivity",
  "planRow",
  "progressRow",
  "progressSuperseded",
  "messageRows",
  "toolRows",
  "toolRowScopes",
  "currentToolScope",
  "planCalls",
  "subagents",
  "groupedPermissions",
  "openQuestions",
  "heldEdits",
  "compactionHeardAt",
  "interrupting",
  "awaiting",
  "stoppingTurn",
  "lateSteers",
  "waitingSteers",
  "bgDoneTurns",
] as const;
/// The live chat's own state, which no page folded forward moves (`landNewer`): it was heard live
/// (`heardAway`, `reduceLiveState`), as `rebuildKeepingLiveState` keeps it.
export const FOLD_LIVE_KEYS = [
  "summary",
  "limitsSeq",
  "limitsVersion",
  "queue",
  "pendingPermission",
  "waitingPermissions",
  "pendingSecret",
  "usage",
  "forkedAtSeq",
  "optimisticPromptRows",
  "promptRowKeys",
  "optimisticPromptTexts",
  "promptAccepts",
  "stopTurnId",
  "retiredCompactionTurnId",
  "compactionFenceSeq",
] as const;

/// The index of the first record in `events` (oldest first) at or after `seq`: a binary search, so
/// a read of the newest records costs O(log held), not a walk over every one.
export function firstHeldFrom(events: readonly EventRecord[], seq: number): number {
  let low = 0;
  let high = events.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (events[middle]!.seq < seq) low = middle + 1;
    else high = middle;
  }
  return low;
}

/// The index of the last record in `events` (oldest first) at or before `seq`, -1 when none is. A row's order need
/// not be a held seq (a prompt drawn before its record comes back sits at `latest + 0.5`, `placeLocalLast`; a page read
/// with a kinds filter leaves holes), so a cut moved back to where a row begins steps to the record before it, never
/// to the same record again (`spanCut`).
export function heldAtOrBefore(events: readonly EventRecord[], seq: number): number {
  const at = firstHeldFrom(events, seq);
  return events[at]?.seq === seq ? at : at - 1;
}

/// Where a cut at `events[cut]` goes back to so that no row is drawn from records on both sides of it: to where the
/// row spanning it begins (`spanningFrom`), until none spans it. Each pass moves the cut to an older record, so it ends
/// within `cut` passes; 0 or less when that reaches the oldest record held. Stepping to the first record at or after
/// where the row begins instead (`firstHeldFrom`) found the same cut again when no held record lay between, and spun
/// with the page's main thread held: Leo's NIGHTLY renderer at 100% CPU and 14 GB, its pages unclosable.
export function spanCut(events: readonly EventRecord[], cut: number, spanningFrom: (seq: number) => number): number {
  while (cut > 0) {
    const { seq } = events[cut]!;
    const from = spanningFrom(seq);
    if (from >= seq) break;
    const older = heldAtOrBefore(events, from);
    // ends: `older` holds a seq at or before `from`, below `seq`, so the cut moves to an older record every pass. A
    // pass that does not (a `spanningFrom` that breaks that) is logged and keeps the cut, never spins.
    if (older >= cut) {
      console.error(`agent pane: a shed cut at seq ${seq} did not move back (row from ${from}); kept`);
      break;
    }
    cut = older;
  }
  return cut;
}

/// Where a rebuild of `events` (held, oldest first) starts folding again: 0 to fold them all, when
/// they fit `window` (`REBUILD_WINDOW`); else the turn start at or before both the newest `window`
/// records and `changedFrom`, the oldest record that changed, and before `openSince` (when a
/// subagent still running started). A turn is folded whole, so the rows above the cut are the same
/// as before it, and the turn before it ended first (`endsTurnBefore`). 0 when no turn starts there.
export function rebuildCut(
  events: readonly EventRecord[],
  changedFrom: number,
  openSince = Infinity,
  window = REBUILD_WINDOW,
): number {
  if (events.length <= window) return 0;
  let at = Math.min(events.length - window, firstHeldFrom(events, changedFrom));
  // Back to the turn a subagent still running started in (`openSince`, its start time).
  while (at > 0 && events[at]!.at >= openSince) at -= 1;
  while (at > 0 && !(startsTurn(events[at]!) && endsTurnBefore(events, at))) at -= 1;
  return at;
}

/// Where a reader scrolled far up lets go of the newest records it holds (`shedNewerHeld`): the first record at or
/// after `events[from]` that starts a turn the one before it ended, so the records kept end between two turns,
/// and that no row or subagent drawn from the records before it goes on in (`spanningFrom`, as `spanCut` reads
/// it): the rows kept are what a fold of the records kept draws, and a page read on from there folds on from a
/// turn's start. -1 when no such record is held. O(the records walked), each at most once.
export function newerCut(events: readonly EventRecord[], from: number, spanningFrom: (seq: number) => number): number {
  for (let at = Math.max(1, from); at < events.length; at += 1) {
    const event = events[at]!;
    if (!startsTurn(event) || !endsTurnBefore(events, at)) continue;
    if (spanningFrom(event.seq) >= event.seq) return at;
  }
  return -1;
}

/// Where a chat left open lets go of its oldest records inside a turn that has not ended (`shedOlderHeld`): a
/// coordinator's turn takes prompts and messages for days and never reaches a `turn_result`, so a cut only at a
/// turn start (`rebuildCut`) never came and the pane held every record it streamed (Leo's coordinator chat: 3.58 GB
/// and 110% CPU). The newest `keep` records, moved back over a subagent still running (`openSince`) and to the
/// oldest row a record past the cut changed (`spanningFrom`, so no row is drawn from only part of its records),
/// until neither moves it. 0 when that reaches the oldest record held. The rows kept are drawn as a page that
/// starts inside the turn is, under the turn's prompt (`turnOpener`).
export function midTurnCut(
  events: readonly EventRecord[],
  keep: number,
  openSince: number,
  spanningFrom: (seq: number) => number,
): number {
  if (events.length <= keep) return 0;
  let at = events.length - keep;
  for (;;) {
    const moved = at;
    while (at > 0 && events[at]!.at >= openSince) at -= 1;
    if (at <= 0) return 0;
    const from = spanningFrom(events[at]!.seq);
    if (from < events[at]!.seq) at = heldAtOrBefore(events, from);
    if (at <= 0) return 0;
    if (at === moved) return at;
  }
}

/// Whether the turn before `events[at]` ended before it: its `turn_result` comes after the agent's
/// last update before `at`. A prompt into a running turn (no result between) goes on drawing that
/// turn's reply in the same row, so a refold that started at it would draw the reply's rest again.
export function endsTurnBefore(events: readonly EventRecord[], at: number): boolean {
  for (let index = at - 1; index >= 0; index -= 1) {
    const event = events[index]!;
    if (event.dir === "mux" && event.kind === "turn_result") return true;
    if (event.dir !== "mux" || startsTurn(event)) return false;
  }
  return true;
}

/// Merges `added` into the held `events` (oldest first) in place: records past the newest held one
/// are appended, others merged into the newest part from the oldest of them, so a read of a recent
/// hole costs O(hole), not a copy of every held record. A record already held is replaced.
export function mergeIntoHeld(events: EventRecord[], added: readonly EventRecord[]): void {
  if (added.length === 0) return;
  const sorted = [...added].sort((left, right) => left.seq - right.seq);
  const from = firstHeldFrom(events, sorted[0]!.seq);
  if (from === events.length) {
    let last = events.at(-1)?.seq ?? -Infinity;
    for (const event of sorted)
      if (event.seq > last) {
        events.push(event);
        last = event.seq;
      } else events[events.length - 1] = event;
    return;
  }
  const tail = mergeEventRecords(events.slice(from), sorted);
  // Not `splice(from, n, ...tail)`: a spread of a long tail overflows the call's argument limit.
  events.length = from;
  for (const event of tail) events.push(event);
}

export function applySupersededMessage(
  rows: Map<string, AcpmuxRow>,
  messageRows: Map<string, string[]>,
  superseded: Set<string>,
  oldMessageId: string,
): void {
  superseded.add(oldMessageId);
  for (const rowId of messageRows.get(oldMessageId) ?? []) rows.delete(rowId);
  messageRows.delete(oldMessageId);
}
