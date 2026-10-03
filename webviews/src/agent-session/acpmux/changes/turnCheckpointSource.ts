// Where a turn's checkpoint pair comes from: acpmux records the checkpoint it took before the
// prompt and the one it took when the turn ended on the turn's `turn_result` (checkpointId,
// endCheckpointId), and the session host diffs the pair (`git.checkpoint.diff`). The answer has
// the shape `TurnCheckpointWire` names (turnCheckpoint.ts).
import { turnRows } from "../diff";
import type { AcpmuxRow } from "../model";
import type { TurnCheckpointWire } from "./turnCheckpoint";

/// A turn's checkpoints as acpmux recorded them: `from` is null when acpmux could not take the
/// starting checkpoint (the prompt went anyway), and `to` is absent when it took no end one.
export type SummaryCheckpoint = { from: string | null; to?: string; reason?: string };

const text = (value: unknown) => (typeof value === "string" && value ? value : undefined);
const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0);

/// The checkpoints on a `turn_result` message, or undefined from an acpmux that records none.
export function readSummaryCheckpoint(message: unknown): SummaryCheckpoint | undefined {
  if (!message || typeof message !== "object" || !("checkpointId" in message)) return undefined;
  const raw = message as Record<string, unknown>;
  const from = text(raw.checkpointId) ?? null;
  const to = text(raw.endCheckpointId);
  const reason = text(raw.checkpointError);
  return { from, ...(to ? { to } : {}), ...(reason ? { reason } : {}) };
}

/// Diffs checkpoint `from` against `to` on the session host.
export type CheckpointDiff = (from: string, to: string) => Promise<unknown>;

/// One turn's checkpoint pair, for the turn that `rowId` starts. A turn that has not ended is
/// refused (the pane asks only once it ends). A summary without checkpoint fields comes from an
/// agent that records none: unsupported. An ended turn without both checkpoints has no pair
/// (null): the working tree now also holds later turns and the user's edits.
export async function readTurnFromRows(
  rows: readonly AcpmuxRow[],
  rowId: string,
  diff: CheckpointDiff,
): Promise<TurnCheckpointWire> {
  const summary = turnRows([...rows], rowId).find((row) => row.kind === "turnSummary");
  if (!summary) throw new Error("The turn has not ended");
  const checkpoint = summary.checkpoint;
  if (!checkpoint) return { unsupported: true };
  if (!checkpoint.from || !checkpoint.to) return null;
  const value = await diff(checkpoint.from, checkpoint.to);
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  return {
    checkpoint_id: `${checkpoint.from}..${checkpoint.to}`,
    // A checkpoint that left files out (too large, over its file limit), or a read that left
    // files out (max_files), leaves the pair incomplete, so the view keeps the tool calls' edits.
    complete: raw.complete === true && count(raw.files_omitted) === 0,
    diff: value,
  };
}
