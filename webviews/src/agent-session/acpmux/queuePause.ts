// Why acpmux paused a chat's queue (`queuePaused`): the error its failed turn ended with, which the
// turn's summary row carries (`turn_result` `errorText`, direct.ts). The queue's paused note names
// it, so a paused queue never just holds messages without saying why.
import type { AcpmuxRow, AcpmuxSnapshot, QueueEdit } from "./model";

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

/// Resumes a paused queue from its first prompt acpmux holds (a held one, trustHeld.ts, is not
/// acpmux's to resume): the paused note's Resume and the status dot's (RFD 0128) are this one.
export function resumePausedQueue(
  queue: AcpmuxSnapshot["queue"],
  onChange: (promptId: string, edit: QueueEdit) => Promise<boolean>,
): void {
  const first = queue.find((row) => !row.held) ?? queue[0];
  if (first) void onChange(first.id, { op: "resume" }).catch(() => undefined);
}
