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
export class PendingPaneDraw {
  private rows: readonly AcpmuxRow[] | undefined;
  get pending(): boolean {
    return this.rows !== undefined;
  }
  /// The pane set `next` (urgent: at once, which overtakes any pending draw).
  drew(next: AcpmuxSnapshot, urgent: boolean): void {
    this.rows = urgent ? undefined : next.rows;
  }
  /// The pane committed `snapshot` (its layout effect).
  committed(snapshot: AcpmuxSnapshot): void {
    if (snapshot.rows === this.rows) this.rows = undefined;
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
