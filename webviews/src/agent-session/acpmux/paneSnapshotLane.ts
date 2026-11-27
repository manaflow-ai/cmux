// When the pane draws a snapshot the direct client sent: at once, or as a transition a key can go
// before (App.tsx, the direct client's snapshot callback).
//
// A snapshot that is not a streamed chunk redraws the whole pane: the transcript, the composer's
// chrome, Session Info. As a default-lane update that render ran in one piece, and a key typed while
// it ran waited for all of it before the page's keydown listener (24% of the renderer main-thread
// time keys waited behind while a reply streamed, bench/shared-renderer-typing.bench.ts --trace).
// As a transition React renders it from scheduler tasks in 5 ms slices with input between them.
//
// What stays consistent while a transition is pending: nothing of it shows until React commits it
// whole, so the transcript's rows, its follow and pin to bottom, the fold set and the scroll
// position are the last committed snapshot's until then, and its list places, measures and scrolls
// once, on commit. The streaming row's draw (streamingRow.ts) is a transition too: React renders
// all pending transitions together, so the pane's rows and the live row commit in one render, and
// the live row's `drawnText` matches the row it draws over. Updates keep their order: React applies
// a state's queued updates in the order they were made, so a later snapshot always wins, including
// over a pending one an urgent draw overtook.
//
// What draws at once (urgent): the first snapshot, another chat's (a chat switch), and one that
// carries what the person just did: a sent prompt's row, a queued or steered prompt, a stop. Those
// answer the person's own gesture, and the composer that sent them redraws at once too: a sent
// message must not leave the composer a frame before the transcript shows it.
import { startTransition } from "react";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { turnPhase } from "./turnPhase";
import { holdSettle, releaseSettle } from "./paneSettle";

/// The id of the last row the person wrote, scanning back from the end (a sent prompt is appended
/// there, so this reads a few rows, not the chat).
function lastUserRow(rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) if (rows[index]!.kind === "user") return rows[index];
  return undefined;
}

function sameIds(a: readonly { id: string }[] | undefined, b: readonly { id: string }[] | undefined): boolean {
  if (a === b) return true;
  if (!a || !b || a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1) if (a[index]!.id !== b[index]!.id) return false;
  return true;
}

function sameList(a: readonly string[] | undefined, b: readonly string[] | undefined): boolean {
  if (a === b) return true;
  if ((a?.length ?? 0) !== (b?.length ?? 0)) return false;
  for (let index = 0; index < (a?.length ?? 0); index += 1) if (a![index] !== b![index]) return false;
  return true;
}

/// Whether `next` draws at once rather than as a transition, given the snapshot the pane last
/// set (`drawn`, undefined before the first).
export function drawsAtOnce(drawn: AcpmuxSnapshot | undefined, next: AcpmuxSnapshot): boolean {
  if (!drawn) return true;
  // A chat switch, or a new chat's first frame.
  if (drawn.sessionId !== next.sessionId) return true;
  // A sent prompt: its row (pending, then delivered or failed), its place in the queue, its steer.
  const before = lastUserRow(drawn.rows);
  const after = lastUserRow(next.rows);
  if (before?.id !== after?.id || before?.pending !== after?.pending || before?.failed !== after?.failed) return true;
  if (!sameIds(drawn.queue, next.queue)) return true;
  if (!sameList(drawn.waitingSteers, next.waitingSteers) || drawn.newestOwnSteer !== next.newestOwnSteer) return true;
  // A stop the person asked for.
  if (drawn.stopping !== next.stopping) return true;
  // Older history the reader scrolled up to: a page that landed above the first row, or what the transcript
  // sizes the room above the rows from (the prompt counts, whether more is left). The reader is scrolling while
  // it lands, and each scroll frame's urgent render restarted a pending transition, so a dragged scroll drew
  // none of the page until it stopped: 15 to 28 blank frames a drag where #45749 had 0
  // (bench/transcript-scroll-up.bench.ts MODE=drag; Leo, 2026-11-22: "scrolling.. bit of blank screening
  // when the content loads").
  if (olderHistoryMoved(drawn, next)) return true;
  // The turn starts or ends, or the link goes up or down: the composer's Send and Stop and the
  // line above it follow the turn's phase, and a deferred phase lets the composer's own state move
  // its buttons a frame before the snapshot that matches them (agentStart.gallery.ts slow-start).
  if (turnPhase(drawn) !== turnPhase(next)) return true;
  // A pick the person made (harness, model, effort and the other config options, access mode)
  // coming back from the daemon: its chip shows the pick until the call settles, then reads the
  // snapshot, so a deferred echo would flash the old value (agent-pane-picks-hold.test.ts).
  if (!samePicks(drawn.summary, next.summary)) return true;
  return false;
}

/// Whether `next` changes the history above the rows: a new first row (a page prepended, or the oldest let
/// go), more or less left to load, or the counts the room above the rows is sized from. O(1).
function olderHistoryMoved(drawn: AcpmuxSnapshot, next: AcpmuxSnapshot): boolean {
  return (
    drawn.rows[0]?.id !== next.rows[0]?.id ||
    drawn.canLoadOlder !== next.canLoadOlder ||
    drawn.historyFrom !== next.historyFrom ||
    drawn.promptCount !== next.promptCount ||
    (drawn.earlierPrompts?.length ?? 0) !== (next.earlierPrompts?.length ?? 0)
  );
}

type Summary = AcpmuxSnapshot["summary"];

function samePicks(a: Summary, b: Summary): boolean {
  if (a === b) return true;
  if (a?.harness !== b?.harness || a?.model !== b?.model) return false;
  if (a?.modes?.currentModeId !== b?.modes?.currentModeId) return false;
  const left = a?.configOptions;
  const right = b?.configOptions;
  if (left === right) return true;
  if ((left?.length ?? 0) !== (right?.length ?? 0)) return false;
  for (let index = 0; index < (left?.length ?? 0); index += 1) {
    if (left![index]!.id !== right![index]!.id || left![index]!.currentValue !== right![index]!.currentValue)
      return false;
  }
  return true;
}

/// Whether the pane has a transition draw it has not committed yet. While it has, a running
/// command's output does not go around the pane (liveToolOutput.ts): that store is read in sync
/// renders, so an entry told from the pending snapshot's rows would leave the committed row
/// without its newer output (its output would go back) until the draw commits. The output goes
/// through the pane's draw instead, which React folds into the pending one.
///
/// A record that would draw the pane again while such a draw is pending waits for it (`owe`): once it
/// commits, the newest record goes through the pane's bypasses from what that draw drew, and draws
/// the pane again only if none takes it. Before, each one set the pane again, which restarts the
/// pending transition, and every record until it committed (each thought chunk, each call) drew the
/// whole pane too: 347 of 969 pane renders a replay window under load (bench replay-under-load
/// RENDERS=1, `miss:…|pending`; goal renderer-main-busy).
export class PendingPaneDraw {
  private rows: readonly AcpmuxRow[] | undefined;
  private owed: (() => void) | undefined;
  get pending(): boolean {
    return this.rows !== undefined;
  }
  /// The pane set `next` (urgent: at once, which overtakes any pending draw and what it owed).
  drew(next: AcpmuxSnapshot, urgent: boolean): void {
    this.rows = urgent ? undefined : next.rows;
    if (urgent) {
      this.owed = undefined;
      releaseSettle(this);
    } else holdSettle(this);
  }
  /// What runs once the pending draw commits; the newest replaces any before it.
  owe(then: () => void): void {
    this.owed = then;
  }
  /// The pane stopped: it owes nothing.
  forget(): void {
    this.owed = undefined;
    releaseSettle(this);
  }
  /// The pane committed `snapshot` (its layout effect).
  committed(snapshot: AcpmuxSnapshot): void {
    if (snapshot.rows !== this.rows) return;
    this.rows = undefined;
    // The live stores' news first (paneSettle.ts), then the record the draw owed.
    releaseSettle(this);
    const owed = this.owed;
    this.owed = undefined;
    owed?.();
  }
}

/// Runs `draw` (the pane's `setSnapshot` of `next`) at once or as a transition, given the
/// snapshot the pane last set (`drawn`), and records it in `pending`.
export function drawPaneSnapshot(
  drawn: AcpmuxSnapshot | undefined,
  next: AcpmuxSnapshot,
  pending: PendingPaneDraw,
  draw: () => void,
): void {
  const urgent = drawsAtOnce(drawn, next);
  pending.drew(next, urgent);
  if (urgent) draw();
  else startTransition(draw);
}
