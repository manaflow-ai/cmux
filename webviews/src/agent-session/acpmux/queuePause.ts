// Why acpmux paused a chat's queue (`queuePaused`): the error its last turn ended with, which the
// turn's summary row carries (`turn_result` `errorText`, direct.ts). The queue's paused note names
// it, so a paused queue never just holds messages without saying why.
import type { AcpmuxRow } from "./model";

/// The error of the chat's last turn; undefined when that turn ended well or named no error.
export function queuePauseReason(rows: readonly AcpmuxRow[]): string | undefined {
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind !== "turnSummary") continue;
    return row.error?.trim() || undefined;
  }
  return undefined;
}
