// Why acpmux paused a chat's queue (`queuePaused`): the error its failed turn ended with, which the
// turn's summary row carries (`turn_result` `errorText`, direct.ts). The queue's paused note names
// it, so a paused queue never just holds messages without saying why.
import type { AcpmuxRow, QueuedPrompt, QueueEdit } from "./model";

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

/// Resume of a paused queue, from the queue's paused note and from the status dot's `resumeQueue`
/// alike: acpmux's first prompt is the one resumed (a held one, trustHeld.ts, is not acpmux's to
/// resume). False with nothing queued.
export function resumeQueue(
  queue: readonly Pick<QueuedPrompt, "id" | "held">[],
  change: (promptId: string, edit: QueueEdit) => Promise<boolean>,
): boolean {
  const first = queue.find((row) => !row.held) ?? queue[0];
  if (!first) return false;
  void change(first.id, { op: "resume" }).catch(() => undefined);
  return true;
}
