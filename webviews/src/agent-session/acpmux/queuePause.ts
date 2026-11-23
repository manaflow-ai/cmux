// Why acpmux paused a chat's queue (`queuePaused`): the error its failed turn ended with, which the
// turn's summary row carries (`turn_result` `errorText`, direct.ts). The queue's paused note names
// it, so a paused queue never just holds messages without saying why.
import type { AcpmuxRow } from "./model";

/// The error of the chat's latest failed turn: a prompt sent meanwhile runs now and may end well
/// while the queue stays held, so a later good turn does not hide why. Undefined with none.
export function queuePauseReason(rows: readonly AcpmuxRow[]): string | undefined {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind !== "turnSummary" || row.status !== "failed") continue;
    return row.error?.trim() || undefined;
  }
  return undefined;
}

/// Whether the chat's latest ended turn was stopped rather than failed: under the opt-in
/// `stop-holds-queue` arm a person's Stop holds their own queue, and the note says Stop, not error.
export function queuePausedByStop(rows: readonly AcpmuxRow[]): boolean {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind !== "turnSummary") continue;
    if (row.status === "failed") return false;
    if (row.status === "cancelled") return true;
  }
  return false;
}
