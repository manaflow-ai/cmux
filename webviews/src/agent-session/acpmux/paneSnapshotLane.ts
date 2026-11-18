// When the pane draws a snapshot the direct client sent (App.tsx, the direct client's snapshot callback):
// `drawsAtOnce` names the snapshots that answer what the person just did or open another chat. For now
// every snapshot draws at once, as a default-lane update; the next commit makes the rest a transition.
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

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
  return false;
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
  // For now every snapshot draws at once.
  void drawsAtOnce;
  pending.drew(next, true);
  draw();
}
